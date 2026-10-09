'use strict'
// One-shot launch requests from the omarchy-tabby CLI.
//
// Threat model: tabby:// is registered as a URL scheme handler, so any web page
// or document can make Tabby receive `tabby://open?...&omarchyRequest=<id>`.
// A request therefore carries no authority by itself: the id must name a file
// that only this user could have created, in a private directory, very
// recently. The file is consumed (unlinked) on first read.

const path = require('path')

const ID_RE = /^[a-f0-9]{32}$/
const ACTIONS = ['open', 'run', 'profile', 'window']
const MAX_BYTES = 64 * 1024
const MAX_AGE_MS = 60 * 1000
const CLOCK_SKEW_MS = 5 * 1000

function isSafeString (s, max) {
    return typeof s === 'string' && s.length <= max && !s.includes('\0')
}

function privateTo (stat, uid) {
    return stat.uid === uid && (stat.mode & 0o077) === 0
}

function validate (req, now) {
    if (!req || typeof req !== 'object' || Array.isArray(req)) return 'not an object'
    if (req.v !== 1) return 'unsupported version'
    if (!ACTIONS.includes(req.action)) return 'unknown action'
    if (typeof req.created !== 'number' || !Number.isFinite(req.created)) return 'missing timestamp'
    if (req.created > now + CLOCK_SKEW_MS || now - req.created > MAX_AGE_MS) return 'expired'
    if (req.cwd !== undefined) {
        if (!isSafeString(req.cwd, 4096)) return 'bad cwd'
        if (req.cwd !== '@active' && !path.isAbsolute(req.cwd)) return 'cwd must be absolute'
    }
    if (req.fallbackCwd !== undefined && (!isSafeString(req.fallbackCwd, 4096) || !path.isAbsolute(req.fallbackCwd))) return 'bad fallbackCwd'
    if (req.title !== undefined && !isSafeString(req.title, 256)) return 'bad title'
    if (req.hold !== undefined && typeof req.hold !== 'boolean') return 'bad hold'
    if (req.action === 'run') {
        if (!Array.isArray(req.argv) || req.argv.length < 1 || req.argv.length > 256) return 'bad argv'
        if (!req.argv.every(a => isSafeString(a, 32768))) return 'bad argv item'
        if (!req.argv[0]) return 'empty command'
    } else if (req.argv !== undefined) {
        return 'argv only allowed for run'
    }
    if (req.action === 'profile') {
        if (!isSafeString(req.profile, 256) || !req.profile) return 'bad profile'
    } else if (req.profile !== undefined) {
        return 'profile only allowed for profile'
    }
    return null
}

// Reads and consumes a request. Returns { request } or { error }.
// `fs` and `uid` are injectable for tests.
function consume (id, { dir, fs = require('fs'), uid = process.getuid(), now = Date.now() } = {}) {
    if (typeof id !== 'string' || !ID_RE.test(id)) return { error: 'invalid request id' }
    let dirStat
    try {
        dirStat = fs.lstatSync(dir)
    } catch {
        return { error: 'request directory missing' }
    }
    if (!dirStat.isDirectory() || !privateTo(dirStat, uid)) return { error: 'request directory is not private' }

    const file = path.join(dir, `${id}.json`)
    let fd
    try {
        fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK)
    } catch {
        return { error: 'request not found' }
    }
    let text
    try {
        const st = fs.fstatSync(fd)
        if (!st.isFile()) return { error: 'request is not a regular file' }
        if (!privateTo(st, uid)) return { error: 'request file is not private' }
        if (st.size > MAX_BYTES) return { error: 'request too large' }
        const buf = Buffer.alloc(st.size)
        let read = 0
        while (read < st.size) {
            const n = fs.readSync(fd, buf, read, st.size - read, read)
            if (n <= 0) break
            read += n
        }
        text = buf.slice(0, read).toString('utf8')
    } finally {
        fs.closeSync(fd)
        try { fs.unlinkSync(file) } catch { /* already consumed */ }
    }

    let req
    try {
        req = JSON.parse(text)
    } catch {
        return { error: 'request is not JSON' }
    }
    const problem = validate(req, now)
    if (problem) return { error: problem }
    return { request: req }
}

module.exports = { ID_RE, ACTIONS, MAX_AGE_MS, validate, consume }
