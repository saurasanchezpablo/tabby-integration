'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const M = require('../Model.js')

const running = {
    tabby: { installed: true, running: true, windows: 1, dropdown: false },
    companion: { installed: true, loaded: true, needsRestart: false },
    tabs: 3,
    colors: 'synced',
    theme: 'tokyo-night',
    profiles: [
        { id: 'local:bash', name: 'bash', type: 'local', builtin: true },
        { id: 'ssh:abc', name: 'prod', type: 'ssh', builtin: false },
        { id: 'local:wsl', name: 'wsl', type: 'wsl', builtin: true },
        { id: '', name: 'broken', type: 'local' },
        null,
    ],
}

test('icons are single private-use glyphs, not empty strings', () => {
    for (const [name, glyph] of Object.entries(M.ICONS)) {
        assert.equal([...glyph].length, 1, name)
        assert.ok(glyph.codePointAt(0) >= 0xE000, name)
    }
})

test('parseStatus never throws', () => {
    assert.deepEqual(M.parseStatus('nope'), {})
    assert.deepEqual(M.parseStatus('[1]'), {})
    assert.deepEqual(M.parseStatus(''), {})
    assert.equal(M.parseStatus(JSON.stringify(running)).tabs, 3)
})

test('bar text shows the tab count only while running', () => {
    assert.equal(M.barText(running, true), M.ICONS.terminal + ' 3')
    assert.equal(M.barText(running, false), M.ICONS.terminal)
    assert.equal(M.barText({ ...running, tabby: { running: false } }, true), M.ICONS.terminal)
    assert.equal(M.barText({}, true), M.ICONS.terminal)
})

test('status line covers every state', () => {
    assert.equal(M.statusLine(running), '3 tabs · 1 window')
    assert.equal(M.statusLine({ ...running, tabs: 1, tabby: { ...running.tabby, windows: 2, dropdown: true } }), '1 tab · 2 windows · dropdown')
    assert.equal(M.statusLine({ tabby: { installed: true, running: false } }), 'Not running')
    assert.equal(M.statusLine({ tabby: { installed: false } }), 'Tabby is not installed')
    assert.equal(M.statusLine({ tabby: { installed: true, running: true }, companion: { needsRestart: true } }), 'Restart Tabby to load the integration')
    assert.equal(M.statusLine({}), 'Not running')
})

test('problem flags a missing Tabby or a needed restart', () => {
    assert.equal(M.problem(running), false)
    assert.equal(M.problem({ companion: { needsRestart: true } }), true)
    assert.equal(M.problem({ tabby: { installed: false } }), true)
})

test('profiles: user first, built-in local shells after, junk dropped, capped', () => {
    assert.deepEqual(M.visibleProfiles(running).map(p => p.id), ['ssh:abc', 'local:bash'])
    const many = { profiles: Array.from({ length: 20 }, (_, i) => ({ id: 'p' + i, name: 'p' + i, type: 'ssh' })) }
    assert.equal(M.visibleProfiles(many).length, M.MAX_PROFILES)
    assert.deepEqual(M.visibleProfiles({ profiles: 'x' }), [])
})

test('sync labels', () => {
    assert.equal(M.syncLabel('synced', 'nord'), 'Synced · nord')
    assert.equal(M.syncLabel('paused'), 'Paused (changed in Tabby)')
    assert.equal(M.syncLabel(undefined), '—')
})

test('settings helpers read the schema list', () => {
    const list = [
        { key: 'syncColors', type: 'boolean', label: 'a', description: 'b' },
        { key: 'tuiTerminal', type: 'enum', options: ['auto', 'foot'] },
        { type: 'boolean' },
    ]
    assert.deepEqual(M.toggleSettings(list).map(s => s.key), ['syncColors'])
    assert.equal(M.enumSetting(list, 'tuiTerminal').options.length, 2)
    assert.equal(M.enumSetting(list, 'nope'), null)
    assert.deepEqual(M.toggleSettings(null), [])
})

test('poll interval is clamped', () => {
    assert.equal(M.clampInterval(1, 4), 2)
    assert.equal(M.clampInterval(600, 4), 60)
    assert.equal(M.clampInterval('x', 4), 4)
})

test('profile icons by type', () => {
    assert.equal(M.profileIcon('ssh'), M.ICONS.server)
    assert.equal(M.profileIcon('local'), M.ICONS.shell)
    assert.equal(M.profileIcon('weird'), M.ICONS.terminal)
})

test('setup needed: marketplace install with only the widget', () => {
    const fresh = { tabby: { installed: true, running: false }, setup: { complete: false } }
    assert.equal(M.setupNeeded(fresh), true)
    assert.equal(M.problem(fresh), true)
    assert.equal(M.statusLine(fresh), 'Integration not set up')
    assert.equal(M.setupNeeded(running), false)
    assert.equal(M.setupNeeded({ setup: { complete: true } }), false)
})
