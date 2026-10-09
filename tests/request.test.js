'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const crypto = require('crypto')
const R = require('../tabby-omarchy/lib/request')

function tmpdir (mode = 0o700) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omarchy-tabby-req-'))
    fs.chmodSync(dir, mode)
    return dir
}

function put (dir, body, { mode = 0o600, id = crypto.randomBytes(16).toString('hex') } = {}) {
    fs.writeFileSync(path.join(dir, `${id}.json`), typeof body === 'string' ? body : JSON.stringify(body), { mode })
    fs.chmodSync(path.join(dir, `${id}.json`), mode)
    return id
}

const base = () => ({ v: 1, action: 'open', created: Date.now(), cwd: '/tmp' })

test('valid request is returned once and the file is consumed', () => {
    const dir = tmpdir()
    const id = put(dir, base())
    const r = R.consume(id, { dir })
    assert.equal(r.error, undefined)
    assert.equal(r.request.action, 'open')
    assert.ok(!fs.existsSync(path.join(dir, `${id}.json`)))
    assert.equal(R.consume(id, { dir }).error, 'request not found')
})

test('rejects ids that are not 32 lowercase hex chars (path traversal)', () => {
    const dir = tmpdir()
    for (const id of ['../../etc/passwd', 'ABCDEF0123456789ABCDEF0123456789', 'a'.repeat(31), 'a'.repeat(33), '', null, 42]) {
        assert.equal(R.consume(id, { dir }).error, 'invalid request id')
    }
})

test('rejects a request directory readable by others', () => {
    const dir = tmpdir(0o755)
    const id = put(dir, base())
    assert.equal(R.consume(id, { dir }).error, 'request directory is not private')
})

test('rejects request files readable by others', () => {
    const dir = tmpdir()
    const id = put(dir, base(), { mode: 0o644 })
    assert.equal(R.consume(id, { dir }).error, 'request file is not private')
})

test('rejects symlinked request files', () => {
    const dir = tmpdir()
    const target = path.join(tmpdir(), 'target.json')
    fs.writeFileSync(target, JSON.stringify(base()), { mode: 0o600 })
    const id = crypto.randomBytes(16).toString('hex')
    fs.symlinkSync(target, path.join(dir, `${id}.json`))
    assert.equal(R.consume(id, { dir }).error, 'request not found')
    assert.ok(fs.existsSync(target), 'symlink target must not be touched')
})

test('rejects FIFOs without hanging', { skip: !fs.existsSync('/usr/bin/mkfifo') }, () => {
    const dir = tmpdir()
    const id = crypto.randomBytes(16).toString('hex')
    require('child_process').execFileSync('mkfifo', ['-m', '600', path.join(dir, `${id}.json`)])
    assert.equal(R.consume(id, { dir }).error, 'request is not a regular file')
})

test('rejects oversized and malformed files', () => {
    const dir = tmpdir()
    assert.equal(R.consume(put(dir, 'x'.repeat(300 * 1024)), { dir }).error, 'request too large')
    assert.equal(R.consume(put(dir, '{nope'), { dir }).error, 'request is not JSON')
})

test('rejects expired and future requests', () => {
    const dir = tmpdir()
    assert.equal(R.consume(put(dir, { ...base(), created: Date.now() - 61000 }), { dir }).error, 'expired')
    assert.equal(R.consume(put(dir, { ...base(), created: Date.now() + 60000 }), { dir }).error, 'expired')
})

test('validate enforces the schema per action', () => {
    const now = Date.now()
    const ok = (r) => R.validate({ v: 1, created: now, ...r }, now)
    assert.equal(ok({ action: 'open' }), null)
    assert.equal(ok({ action: 'open', cwd: '@active', fallbackCwd: '/home' }), null)
    assert.equal(ok({ action: 'run', argv: ['htop'] }), null)
    assert.equal(ok({ action: 'profile', profile: 'ssh-prod' }), null)
    assert.equal(ok({ action: 'window' }), null)
    assert.equal(ok({ action: 'exec' }), 'unknown action')
    assert.equal(ok({ action: 'open', cwd: 'relative' }), 'cwd must be absolute')
    assert.equal(ok({ action: 'open', cwd: '/tmp\0x' }), 'bad cwd')
    assert.equal(ok({ action: 'open', argv: ['x'] }), 'argv only allowed for run')
    assert.equal(ok({ action: 'run', argv: [] }), 'bad argv')
    assert.equal(ok({ action: 'run', argv: [''] }), 'empty command')
    assert.equal(ok({ action: 'run', argv: ['a', 5] }), 'bad argv item')
    assert.equal(ok({ action: 'run', argv: new Array(300).fill('a') }), null)
    assert.equal(ok({ action: 'run', argv: new Array(5000).fill('a') }), 'bad argv')
    assert.equal(ok({ action: 'profile' }), 'bad profile')
    assert.equal(ok({ action: 'open', profile: 'x' }), 'profile only allowed for profile')
    assert.equal(ok({ action: 'open', title: 'x'.repeat(300) }), 'bad title')
    assert.equal(ok({ action: 'open', hold: 'yes' }), 'bad hold')
    assert.equal(R.validate({ v: 2, action: 'open', created: now }, now), 'unsupported version')
    assert.equal(R.validate([], now), 'not an object')
})
