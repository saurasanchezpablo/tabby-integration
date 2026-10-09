'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const S = require('../tabby-omarchy/lib/settings')
const M = require('../tabby-omarchy/lib/misc')
const { paths } = require('../tabby-omarchy/lib/paths')

test('defaults come from the schema', () => {
    const d = S.defaults()
    assert.deepEqual(Object.keys(d).sort(), Object.keys(S.SCHEMA).sort())
    assert.equal(d.syncColors, true)
    assert.equal(d.tuiTerminal, 'auto')
})

test('normalize keeps valid values and drops wrong types and unknown keys', () => {
    const s = S.normalize({ syncColors: false, syncFont: 'no', tuiTerminal: 'foot', evil: 1, __proto__: { x: 1 } })
    assert.equal(s.syncColors, false)
    assert.equal(s.syncFont, true)
    assert.equal(s.tuiTerminal, 'foot')
    assert.equal(s.evil, undefined)
    assert.equal(S.normalize({ tuiTerminal: 'xterm' }).tuiTerminal, 'auto')
})

test('parse survives garbage', () => {
    assert.deepEqual(S.parse('not json'), S.defaults())
    assert.deepEqual(S.parse('[1,2]'), S.defaults())
    assert.deepEqual(S.parse('null'), S.defaults())
})

test('schema entries are complete', () => {
    for (const [key, spec] of Object.entries(S.SCHEMA)) {
        assert.ok(['boolean', 'enum'].includes(spec.type), key)
        assert.ok(S.validValue(spec, spec.default), key)
        assert.ok(spec.label && spec.description, key)
    }
})

test('hotkey helpers are idempotent', () => {
    assert.deepEqual(M.withKey(['Ctrl-Shift-C'], M.COPY_KEY), ['Ctrl-Shift-C', 'Ctrl-Insert'])
    assert.deepEqual(M.withKey(['Ctrl-Insert'], M.COPY_KEY), ['Ctrl-Insert'])
    assert.deepEqual(M.withKey(undefined, M.COPY_KEY), ['Ctrl-Insert'])
    assert.deepEqual(M.withoutKey(['Ctrl-Shift-C', 'Ctrl-Insert'], M.COPY_KEY), ['Ctrl-Shift-C'])
})

test('parseFontFamily mirrors omarchy-font-current', () => {
    assert.equal(M.parseFontFamily('JetBrainsMono Nerd Font,JetBrainsMono NF\n'), 'JetBrainsMono Nerd Font')
    assert.equal(M.parseFontFamily(''), null)
    assert.equal(M.parseFontFamily('x}; body{color:red'), null)
})

test('paths follow XDG variables', () => {
    const p = paths({ HOME: '/h', XDG_RUNTIME_DIR: '/run/user/9', XDG_CONFIG_HOME: '/c', XDG_STATE_HOME: '/s' }, 9)
    assert.equal(p.requestsDir, '/run/user/9/omarchy-tabby/requests')
    assert.equal(p.settingsFile, '/c/omarchy-tabby/settings.json')
    assert.equal(p.backupFile, '/s/omarchy-tabby/tabby-backup.json')
    assert.equal(p.themeDir, '/h/.local/state/omarchy/current/theme')
    const q = paths({ HOME: '/h' }, 9)
    assert.equal(q.runtimeBase, '/run/user/9/omarchy-tabby')
})
