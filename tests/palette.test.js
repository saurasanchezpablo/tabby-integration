'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { execFileSync } = require('child_process')
const P = require('../tabby-omarchy/lib/palette')

const THEME_DIRS = ['/usr/share/omarchy/themes', path.join(process.env.HOME || '', '.config/omarchy/themes')]
const RESOLVER = '/usr/share/omarchy/bin/omarchy-theme-color'

function themeFiles () {
    const out = []
    for (const dir of THEME_DIRS) {
        let names = []
        try { names = fs.readdirSync(dir) } catch { continue }
        for (const name of names) {
            const file = path.join(dir, name, 'colors.toml')
            if (fs.existsSync(file)) out.push(file)
        }
    }
    return out
}

test('parses quoted, unquoted, commented and hostile lines like Omarchy', () => {
    const raw = P.parseColorsToml([
        '# comment',
        'background = "#112233" # trailing',
        "foreground='#ABCDEF'",
        'accent = #fff',
        'bad key = "#000000"',
        'evil = "$(touch /tmp/x)"',
        'amp = "a&b"',
        '',
    ].join('\n'))
    assert.equal(raw.background, '#112233')
    assert.equal(raw.foreground, '#ABCDEF')
    assert.equal(raw.accent, '#fff')
    assert.equal(raw.badkey, '#000000') // spaces are stripped from keys, as in omarchy-theme-color
    assert.equal(raw.evil, undefined)
    assert.equal(raw.amp, undefined)
})

test('mixColor matches the awk implementation', () => {
    assert.equal(P.mixColor('#ff0000', '#ffffff', 0.2), '#ff3333')
    assert.equal(P.mixColor('#1B1B1B', '#000000', 0.5), '#0e0e0e')
})

test('legacy ANSI-only themes get semantic keys', () => {
    const toml = Array.from({ length: 16 }, (_, i) => `color${i} = "#${String(i).padStart(2, '0')}0000"`).join('\n')
    const pal = P.resolvePalette(P.parseColorsToml(toml))
    assert.equal(pal.background, '#000000')
    assert.equal(pal.foreground, '#070000')
    assert.equal(pal.red, '#010000')
    assert.equal(pal.muted, '#080000')
    assert.equal(pal.cursor, '#150000')
})

test('light mode detection: key, file, luminance', () => {
    assert.equal(P.resolvePalette({ background: '#000000', mode: 'light' }).mode, 'light')
    assert.equal(P.resolvePalette({ background: '#000000' }, { lightModeFile: true }).mode, 'light')
    assert.equal(P.resolvePalette({ background: '#f0f0f0' }).mode, 'light')
    assert.equal(P.resolvePalette({ background: '#101010' }).mode, 'dark')
})

test('toTabbyScheme builds a 16-colour scheme and rejects broken palettes', () => {
    const toml = fs.readFileSync(themeFiles()[0] || '/dev/null', 'utf8')
    const scheme = P.schemeFromToml(toml)
    if (toml) {
        assert.equal(scheme.name, 'Omarchy')
        assert.equal(scheme.colors.length, 16)
        for (const c of [scheme.foreground, scheme.background, scheme.cursor, ...scheme.colors]) {
            assert.match(c, /^#[0-9a-f]{6}([0-9a-f]{2})?$/)
        }
    }
    assert.equal(P.schemeFromToml(''), null)
    assert.equal(P.schemeFromToml('background = "nope"\nforeground = "#ffffff"'), null)
})

test('normalizeColor handles hex shorthand, rgb() and junk', () => {
    assert.equal(P.normalizeColor('#ABC'), '#aabbcc')
    assert.equal(P.normalizeColor('rgb(255, 0, 16)'), '#ff0010')
    assert.equal(P.normalizeColor('rgb(300,0,0)'), null)
    assert.equal(P.normalizeColor('red'), null)
})

test('sameScheme compares every field', () => {
    const a = P.schemeFromToml(Array.from({ length: 16 }, (_, i) => `color${i} = "#0000${String(i).padStart(2, '0')}"`).join('\n'))
    assert.ok(a)
    const b = JSON.parse(JSON.stringify(a))
    assert.ok(P.sameScheme(a, b))
    b.colors[3] = '#123456'
    assert.ok(!P.sameScheme(a, b))
    assert.ok(!P.sameScheme(a, null))
})

test('resolvePalette is identical to omarchy-theme-color --all for every installed theme', { skip: !fs.existsSync(RESOLVER) }, () => {
    const files = themeFiles()
    assert.ok(files.length > 0, 'no themes found')
    for (const file of files) {
        const expected = {}
        const out = execFileSync('bash', [RESOLVER, '--file', file, '--all'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
        for (const line of out.split('\n')) {
            if (!line) continue
            const [k, ...v] = line.split('\t')
            expected[k] = v.join('\t')
        }
        const lightModeFile = fs.existsSync(path.join(path.dirname(file), 'light.mode'))
        const actual = P.resolvePalette(P.parseColorsToml(fs.readFileSync(file, 'utf8')), { lightModeFile })
        for (const k of Object.keys(expected)) {
            if (expected[k] === '') continue
            assert.equal(actual[k], expected[k], `${file}: ${k}`)
        }
    }
})
