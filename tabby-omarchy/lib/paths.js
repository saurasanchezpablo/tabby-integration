'use strict'
const path = require('path')
const os = require('os')

// All locations in one place. `env` is injectable for tests.
// OMARCHY_TABBY_{RUNTIME,CONFIG,STATE}_DIR override our own directories (used
// by the integration tests to run an isolated Tabby next to the real one);
// they must match what bin/omarchy-tabby uses.
function paths (env = process.env, uid = (process.getuid ? process.getuid() : 0)) {
    const home = env.HOME || os.homedir()
    const runtime = env.XDG_RUNTIME_DIR || `/run/user/${uid}`
    const configHome = env.XDG_CONFIG_HOME || path.join(home, '.config')
    const stateHome = env.XDG_STATE_HOME || path.join(home, '.local/state')
    const base = env.OMARCHY_TABBY_RUNTIME_DIR || path.join(runtime, 'omarchy-tabby')
    const configDir = env.OMARCHY_TABBY_CONFIG_DIR || path.join(configHome, 'omarchy-tabby')
    const stateDir = env.OMARCHY_TABBY_STATE_DIR || path.join(stateHome, 'omarchy-tabby')
    return {
        home,
        runtimeBase: base,
        requestsDir: path.join(base, 'requests'),
        windowsDir: path.join(base, 'windows'),
        controlFile: path.join(base, 'control.json'),
        settingsFile: path.join(configDir, 'settings.json'),
        stateDir,
        backupFile: path.join(stateDir, 'tabby-backup.json'),
        // Omarchy hard-codes ~/.local/state for the current theme (omarchy-theme-set).
        omarchyCurrentDir: path.join(home, '.local/state/omarchy/current'),
        themeDir: path.join(home, '.local/state/omarchy/current/theme'),
        themeNameFile: path.join(home, '.local/state/omarchy/current/theme.name'),
        fontconfigDir: path.join(configHome, 'fontconfig'),
    }
}

module.exports = { paths }
