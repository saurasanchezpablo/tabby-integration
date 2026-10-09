'use strict'
// tabby-omarchy: the Tabby half of the Omarchy integration.
//
// Plain CommonJS on purpose: Tabby ships the Angular JIT compiler, so the
// decorators are applied by hand and nothing needs a build step. All logic
// that can be tested without Tabby lives in ./lib.
//
// Responsibilities (each can be switched off in ~/.config/omarchy-tabby/settings.json):
//   * colour scheme provider + live sync with the current Omarchy theme
//   * font sync with `omarchy font set`
//   * Ctrl-Insert copy so Omarchy's universal clipboard works
//   * one-shot launch requests from `omarchy-tabby` (see lib/request.js)
//   * per-window state for the Omarchy bar widget

const fs = require('fs')
const path = require('path')
const { execFile } = require('child_process')
const { NgModule, Injectable, Injector, NgZone, inject } = require('@angular/core')
const { ConfigService, AppService, HostWindowService, HostAppService, ProfilesService, NotificationsService, CLIHandler } = require('tabby-core')
const { TerminalColorSchemeProvider } = require('tabby-terminal')

const palette = require('./lib/palette')
const settingsLib = require('./lib/settings')
const request = require('./lib/request')
const { paths } = require('./lib/paths')
const { COPY_KEY, withKey, withoutKey, parseFontFamily, debounce } = require('./lib/misc')
const PLUGIN_VERSION = require('./package.json').version

const LOG = '[tabby-omarchy]'
const POLL_MS = 10000

function readText (file) {
    try { return fs.readFileSync(file, 'utf8') } catch { return null }
}

function statSig (file) {
    try {
        const st = fs.statSync(file)
        return `${st.mtimeMs}:${st.size}:${st.ino}`
    } catch {
        return '-'
    }
}

function clone (value) {
    return value === undefined ? null : JSON.parse(JSON.stringify(value))
}

// mkdir -p with mode 0700. Tightens a directory we own; refuses symlinks and
// directories owned by someone else.
function ensurePrivateDir (dir) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 })
    const st = fs.lstatSync(dir)
    if (!st.isDirectory() || st.uid !== process.getuid()) {
        throw new Error(`${dir} is not a directory owned by us`)
    }
    if ((st.mode & 0o077) !== 0) fs.chmodSync(dir, 0o700)
}

function writeFileAtomic (file, text) {
    const tmp = `${file}.${process.pid}.${Date.now()}.tmp`
    fs.writeFileSync(tmp, text, { mode: 0o600, flag: 'wx' })
    fs.renameSync(tmp, file)
}

function currentScheme () {
    const p = paths()
    const toml = readText(path.join(p.themeDir, 'colors.toml'))
    if (!toml) return null
    return palette.schemeFromToml(toml, { lightModeFile: fs.existsSync(path.join(p.themeDir, 'light.mode')) })
}

class OmarchyColorSchemes extends TerminalColorSchemeProvider {
    async getSchemes () {
        const scheme = currentScheme()
        return scheme ? [scheme] : []
    }
}
Injectable()(OmarchyColorSchemes)

class OmarchyIntegration {
    constructor () {
        this.config = inject(ConfigService)
        this.app = inject(AppService)
        this.zone = inject(NgZone)
        this.injector = inject(Injector)
        this.p = paths()
        this.alive = true
        this.watchers = []
        this.timers = []
        this.settings = settingsLib.defaults()
        this.status = { colors: 'off', font: 'off', clipboard: false, theme: null, fontFamily: null }
        this.lastSig = ''
        this.lastControl = 0
        this.syncing = Promise.resolve()

        this.writeStateSoon = debounce(() => this.writeState(), 250)
        this.syncSoon = debounce(() => this.queueSync(false), 300)

        this.config.ready$.toPromise().then(() => this.start()).catch(err => console.error(LOG, 'start failed', err))
    }

    start () {
        if (!this.alive) return
        this.settings = settingsLib.load(fs, this.p.settingsFile)
        const control = this.readControl()
        this.lastControl = typeof control.apply === 'number' ? control.apply : 0
        this.lastSig = this.signature()
        this.queueSync(false)

        this.watch(this.p.omarchyCurrentDir)
        this.watch(path.dirname(this.p.settingsFile))
        this.watch(this.p.fontconfigDir)
        this.watch(this.p.runtimeBase, name => name === 'control.json')
        this.timers.push(setInterval(() => {
            if (this.signature() !== this.lastSig) this.syncSoon()
        }, POLL_MS))

        this.config.changed$.subscribe(() => this.writeStateSoon())
        this.app.tabsChanged$.subscribe(() => this.writeStateSoon())
        this.app.activeTabChange$.subscribe(() => this.writeStateSoon())
        window.addEventListener('focus', () => this.writeStateSoon())
        window.addEventListener('blur', () => this.writeStateSoon())
        window.addEventListener('beforeunload', () => this.stop())
        this.writeStateSoon()
    }

    stop () {
        this.alive = false
        for (const w of this.watchers) { try { w.close() } catch { /* closed */ } }
        for (const t of this.timers) clearInterval(t)
        this.writeStateSoon.cancel()
        this.syncSoon.cancel()
        try { fs.unlinkSync(this.stateFile()) } catch { /* gone */ }
    }

    // fs.watch breaks when the watched directory is replaced, and Omarchy
    // replaces the theme directory with rm+mv, so we watch parents and also
    // poll a cheap signature as a safety net.
    watch (dir, filter) {
        try {
            const w = fs.watch(dir, { persistent: false }, (_event, name) => {
                if (!filter || filter(String(name || ''))) this.syncSoon()
            })
            w.on('error', () => { /* poll covers it */ })
            this.watchers.push(w)
        } catch {
            // Directory does not exist yet; the poll notices when it appears.
        }
    }

    signature () {
        return [
            statSig(path.join(this.p.themeDir, 'colors.toml')),
            readText(this.p.themeNameFile),
            statSig(this.p.settingsFile),
            statSig(path.join(this.p.fontconfigDir, 'fonts.conf')),
            statSig(this.p.controlFile),
        ].join('|')
    }

    readControl () {
        try {
            const st = fs.lstatSync(this.p.controlFile)
            if (!st.isFile() || st.uid !== process.getuid() || st.size > 4096) return {}
            const c = JSON.parse(readText(this.p.controlFile) || '{}')
            return c && typeof c === 'object' ? c : {}
        } catch {
            return {}
        }
    }

    queueSync (forceOverride) {
        this.syncing = this.syncing.then(() => this.sync(forceOverride)).catch(err => {
            console.error(LOG, 'sync failed', err)
        })
        return this.syncing
    }

    readBackup () {
        try {
            const b = JSON.parse(readText(this.p.backupFile) || '{}')
            return b && typeof b === 'object' ? b : {}
        } catch {
            return {}
        }
    }

    writeBackup (backup) {
        ensurePrivateDir(this.p.stateDir)
        writeFileAtomic(this.p.backupFile, JSON.stringify(backup, null, 2) + '\n')
    }

    async sync (forceOverride) {
        if (!this.alive || !this.config.store) return
        // Uninstalled while Tabby runs: stop instead of falling back to the
        // default settings (which would re-apply the theme just restored).
        if (!fs.existsSync(path.join(__dirname, 'package.json'))) {
            console.info(LOG, 'plugin files removed, stopping')
            this.stop()
            return
        }
        this.lastSig = this.signature()
        this.settings = settingsLib.load(fs, this.p.settingsFile)

        // `omarchy-tabby apply` bumps control.json; a newer stamp than the one
        // seen at startup forces Omarchy colours/font over a manual choice.
        const control = this.readControl()
        let force = Boolean(forceOverride)
        if (typeof control.apply === 'number' && control.apply > this.lastControl) {
            force = true
            this.lastControl = control.apply
        }

        const store = this.config.store
        const backup = this.readBackup()
        let changed = false
        let backupChanged = false

        // Colours ------------------------------------------------------------
        const current = store.terminal.colorScheme
        const ours = current && current.name === palette.SCHEME_NAME
        this.status.theme = (readText(this.p.themeNameFile) || '').trim() || null
        if (this.settings.syncColors) {
            const scheme = currentScheme()
            if (!scheme) {
                this.status.colors = 'error'
            } else if (ours || !backup.colors || force) {
                if (!backup.colors || (force && !ours)) {
                    backup.colors = {
                        colorScheme: clone(store.terminal.colorScheme),
                        lightColorScheme: clone(store.terminal.lightColorScheme),
                    }
                    backupChanged = true
                }
                for (const key of ['colorScheme', 'lightColorScheme']) {
                    if (!palette.sameScheme(store.terminal[key], scheme)) {
                        store.terminal[key] = { ...scheme, colors: scheme.colors.slice() }
                        changed = true
                    }
                }
                this.status.colors = 'synced'
            } else {
                this.status.colors = 'paused'
            }
        } else {
            if (backup.colors) {
                if (ours) {
                    store.terminal.colorScheme = backup.colors.colorScheme ?? undefined
                    store.terminal.lightColorScheme = backup.colors.lightColorScheme ?? undefined
                    changed = true
                }
                delete backup.colors
                backupChanged = true
            }
            this.status.colors = 'off'
        }

        // Font ---------------------------------------------------------------
        if (this.settings.syncFont) {
            const family = await this.omarchyFont()
            const font = store.terminal.font
            const fontOurs = backup.font && font === backup.font.applied
            if (!family) {
                this.status.font = 'error'
            } else if (fontOurs || !backup.font || force) {
                if (!backup.font) {
                    backup.font = { original: font, applied: family }
                    backupChanged = true
                } else if (backup.font.applied !== family) {
                    backup.font.applied = family
                    backupChanged = true
                }
                if (font !== family) {
                    store.terminal.font = family
                    changed = true
                }
                this.status.font = 'synced'
            } else {
                this.status.font = 'paused'
            }
            this.status.fontFamily = family
        } else {
            if (backup.font) {
                if (store.terminal.font === backup.font.applied) {
                    store.terminal.font = backup.font.original
                    changed = true
                }
                delete backup.font
                backupChanged = true
            }
            this.status.font = 'off'
        }

        // Clipboard ------------------------------------------------------------
        const copy = store.hotkeys.copy
        if (this.settings.clipboardKeys) {
            if (!copy.includes(COPY_KEY)) {
                store.hotkeys.copy = withKey(copy, COPY_KEY)
                backup.addedCopyKey = true
                backupChanged = true
                changed = true
            }
            this.status.clipboard = true
        } else {
            if (backup.addedCopyKey) {
                if (copy.includes(COPY_KEY)) {
                    store.hotkeys.copy = withoutKey(copy, COPY_KEY)
                    changed = true
                }
                delete backup.addedCopyKey
                backupChanged = true
            }
            this.status.clipboard = false
        }

        if (backupChanged) {
            try {
                this.writeBackup(backup)
            } catch (err) {
                console.error(LOG, 'cannot write backup', err)
            }
        }
        if (changed && this.alive) {
            await this.zone.run(() => this.config.save())
            console.info(LOG, 'applied Omarchy settings', this.status)
        }
        this.writeStateSoon()
    }

    omarchyFont () {
        return new Promise(resolve => {
            execFile('fc-match', ['monospace', '-f', '%{family}\n'], { timeout: 3000 }, (err, stdout) => {
                resolve(err ? null : parseFontFamily(stdout))
            })
        })
    }

    stateFile () {
        return path.join(this.p.windowsDir, `${process.pid}.json`)
    }

    async writeState () {
        if (!this.alive) return
        try {
            let profiles = []
            try {
                const all = await this.injector.get(ProfilesService).getProfiles({ includeBuiltin: true })
                profiles = all
                    .filter(p => !p.isTemplate)
                    .slice(0, 100)
                    .map(p => ({
                        id: String(p.id || ''),
                        name: String(p.name || ''),
                        type: String(p.type || ''),
                        group: p.group ? String(p.group) : '',
                        builtin: Boolean(p.isBuiltin),
                    }))
            } catch (err) {
                console.warn(LOG, 'cannot list profiles', err)
            }
            const state = {
                v: 1,
                pid: process.pid,
                plugin: PLUGIN_VERSION,
                updated: Date.now(),
                focused: document.hasFocus(),
                tabs: this.app.tabs.length,
                status: this.status,
                profiles,
            }
            ensurePrivateDir(this.p.runtimeBase)
            ensurePrivateDir(this.p.windowsDir)
            writeFileAtomic(this.stateFile(), JSON.stringify(state) + '\n')
        } catch (err) {
            console.warn(LOG, 'cannot write state', err)
        }
    }

    async activeCwd () {
        let tab = this.app.activeTab
        if (tab && typeof tab.getFocusedTab === 'function') tab = tab.getFocusedTab() || tab
        const session = tab && tab.session
        try {
            if (session && session.supportsWorkingDirectory && session.supportsWorkingDirectory()) {
                return await session.getWorkingDirectory()
            }
        } catch { /* fall through */ }
        return null
    }

    async resolveCwd (req) {
        let cwd = req.cwd
        if (cwd === '@active') cwd = await this.activeCwd()
        for (const candidate of [cwd, req.fallbackCwd]) {
            try {
                if (candidate && fs.statSync(candidate).isDirectory()) return candidate
            } catch { /* try next */ }
        }
        return null
    }

    async handleRequest (id) {
        const result = request.consume(id, { dir: this.p.requestsDir })
        if (result.error) {
            console.warn(LOG, 'rejected request:', result.error)
            this.injector.get(NotificationsService).error(`Omarchy: ${result.error}`)
            return
        }
        const req = result.request
        const cwd = await this.resolveCwd(req)
        let tab = null
        if (req.action === 'window') {
            this.injector.get(HostAppService).newWindow()
            return
        }
        const { TerminalService } = require('tabby-local')
        const terminal = this.injector.get(TerminalService)
        if (req.action === 'open') {
            tab = await terminal.openTab(null, cwd)
        } else if (req.action === 'run') {
            tab = await terminal.openTab({
                type: 'local',
                name: req.title || path.basename(req.argv[0]),
                options: { command: req.argv[0], args: req.argv.slice(1), pauseAfterExit: Boolean(req.hold) },
            }, cwd, Boolean(req.hold))
        } else if (req.action === 'profile') {
            const profilesService = this.injector.get(ProfilesService)
            const all = await profilesService.getProfiles({ includeBuiltin: true })
            const profile = all.find(p => p.id === req.profile) || all.find(p => p.name === req.profile)
            if (!profile) {
                this.injector.get(NotificationsService).error(`Omarchy: no Tabby profile "${req.profile}"`)
                return
            }
            if (cwd && profile.type === 'local') {
                tab = await terminal.openTab(profile, cwd)
            } else {
                tab = await profilesService.openNewTabForProfile(profile)
            }
        }
        if (tab && req.title && typeof tab.setCustomTitle === 'function') tab.setCustomTitle(req.title)
        if (this.settings.focusOnOpen) this.injector.get(HostWindowService).bringToFront()
    }
}
Injectable({ providedIn: 'root' })(OmarchyIntegration)

class OmarchyCLIHandler extends CLIHandler {
    constructor () {
        super()
        this.priority = 100
        this.firstMatchOnly = true
        this.injector = inject(Injector)
    }

    async handle (event) {
        const id = event && event.argv ? event.argv.omarchyRequest : undefined
        if (id === undefined || id === null) return false
        await this.injector.get(OmarchyIntegration).handleRequest(String(id))
        return true
    }
}
Injectable()(OmarchyCLIHandler)

class OmarchyModule {
    constructor () {
        inject(OmarchyIntegration)
    }
}
NgModule({
    providers: [
        { provide: TerminalColorSchemeProvider, useClass: OmarchyColorSchemes, multi: true },
        { provide: CLIHandler, useClass: OmarchyCLIHandler, multi: true },
    ],
})(OmarchyModule)

module.exports = OmarchyModule
module.exports.default = OmarchyModule
