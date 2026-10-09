'use strict'
// Omarchy colors.toml -> Tabby TerminalColorScheme.
//
// parseColorsToml + resolvePalette port /usr/share/omarchy/bin/omarchy-theme-color
// so Tabby gets exactly the palette Omarchy bakes into alacritty/kitty/ghostty.
// tests/palette.test.js checks parity against that script for every theme.

const KEY_RE = /^[A-Za-z0-9_-]+$/
const VALUE_RE = /^[A-Za-z0-9#(),._+/% -]*$/
const HEX_RE = /^#[0-9A-Fa-f]{6}$/

const SCHEME_NAME = 'Omarchy'

function parseColorsToml (text) {
    const colors = {}
    for (const line of String(text || '').split('\n')) {
        const eq = line.indexOf('=')
        let key = (eq < 0 ? line : line.slice(0, eq)).replace(/["' \t\r]/g, '')
        let value = eq < 0 ? '' : line.slice(eq + 1)
        if (!key || key.startsWith('#')) {
            continue
        }
        const quote = value.search(/["']/)
        if (quote >= 0) {
            value = value.slice(quote + 1)
            const end = value.search(/["']/)
            if (end >= 0) {
                value = value.slice(0, end)
            }
        } else {
            value = value.trim()
        }
        if (!KEY_RE.test(key) || !VALUE_RE.test(value)) {
            continue
        }
        colors[key] = value
    }
    return colors
}

function mixColor (start, end, amount) {
    const parse = hex => {
        const h = String(hex || '').replace(/^#/, '')
        const v = i => {
            const pair = h.substr(i, 2).toLowerCase()
            let n = 0
            for (const c of pair) {
                n = n * 16 + ('0123456789abcdef'.indexOf(c))
            }
            return n
        }
        return [v(0), v(2), v(4)]
    }
    const a = parse(start)
    const b = parse(end)
    const out = a.map((x, i) => Math.floor(x * (1 - amount) + b[i] * amount + 0.5))
    return '#' + out.map(x => x.toString(16).padStart(2, '0')).join('')
}

function resolvePalette (raw, { lightModeFile = false } = {}) {
    const c = { ...raw }
    const has = k => Boolean(c[k])
    const alias = (k, from) => { if (!has(k)) c[k] = c[from] || '' }

    const legacyPalette = {
        background: 'bg',
        dark_background: 'dark_bg',
        darker_background: 'darker_bg',
        lighter_background: 'lighter_bg',
        foreground: 'fg',
        dark_foreground: 'dark_fg',
        light_foreground: 'light_fg',
        bright_foreground: 'bright_fg',
    }
    for (const [k, from] of Object.entries(legacyPalette)) alias(k, from)

    if (!has('background')) c.background = c.color0 || ''
    if (!has('foreground')) c.foreground = c.color7 || ''
    if (has('background')) c.color0 = c.background
    if (has('foreground')) c.color7 = c.foreground

    const legacyAnsi = {
        red: 'color1', green: 'color2', yellow: 'color3', blue: 'color4', magenta: 'color5', cyan: 'color6',
        bright_red: 'color9', bright_green: 'color10', bright_yellow: 'color11', bright_blue: 'color12',
        bright_magenta: 'color13', bright_cyan: 'color14',
    }
    for (const [k, from] of Object.entries(legacyAnsi)) alias(k, from)
    alias('magenta', 'purple')
    alias('bright_magenta', 'bright_purple')

    if (!has('light_foreground')) c.light_foreground = c.color7 || c.foreground || ''
    if (!has('bright_foreground')) c.bright_foreground = c.color15 || c.foreground || ''
    c.cursor = c.bright_foreground
    if (!has('lighter_background')) c.lighter_background = c.color0 || c.background || ''
    if (!has('dark_foreground')) c.dark_foreground = c.color8 || c.foreground || ''
    if (!has('muted')) c.muted = c.color8 || c.dark_foreground || ''
    if (!has('selection')) c.selection = c.selection_background || c.color8 || c.color0 || c.background || ''
    if (!has('selection_background')) c.selection_background = c.selection
    if (!has('selection_foreground')) c.selection_foreground = c.bright_foreground
    if (!has('orange')) c.orange = c.yellow || ''
    if (!has('brown')) c.brown = mixColor(c.orange, '#000000', 0.5)

    if (!has('dark_background')) c.dark_background = mixColor(c.background, '#000000', 0.25)
    if (!has('darker_background')) c.darker_background = mixColor(c.background, '#000000', 0.5)
    for (const k of ['red', 'yellow', 'green', 'cyan', 'blue', 'magenta']) {
        if (!has(`bright_${k}`)) c[`bright_${k}`] = mixColor(c[k], '#ffffff', 0.2)
    }
    alias('purple', 'magenta')
    alias('bright_purple', 'bright_magenta')

    const ansi = [
        'background', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'foreground',
        'muted', 'bright_red', 'bright_green', 'bright_yellow', 'bright_blue', 'bright_magenta', 'bright_cyan', 'bright_foreground',
    ]
    ansi.forEach((k, i) => alias(`color${i}`, k))

    for (const [k, short] of Object.entries(legacyPalette)) {
        if (has(k)) c[short] = c[k]
    }

    if (!has('mode')) c.mode = c.theme_type || ''
    if (!has('mode')) {
        if (lightModeFile) {
            c.mode = 'light'
        } else if (HEX_RE.test(c.background)) {
            const h = c.background.slice(1)
            const lum = parseInt(h.slice(0, 2), 16) + parseInt(h.slice(2, 4), 16) + parseInt(h.slice(4, 6), 16)
            c.mode = lum > 382 ? 'light' : 'dark'
        } else {
            c.mode = 'dark'
        }
    }
    c.theme_type = c.mode

    for (const k of Object.keys(c)) {
        if (c[k] === '') delete c[k]
    }
    return c
}

// Same ANSI mapping as Omarchy's alacritty/kitty/ghostty/foot templates.
const ANSI_KEYS = [
    'background', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'foreground',
    'muted', 'bright_red', 'bright_green', 'bright_yellow', 'bright_blue', 'bright_magenta', 'bright_cyan', 'bright_foreground',
]

function normalizeColor (value) {
    const v = String(value || '').trim()
    if (/^#[0-9A-Fa-f]{6}$/.test(v) || /^#[0-9A-Fa-f]{8}$/.test(v)) return v.toLowerCase()
    if (/^#[0-9A-Fa-f]{3}$/.test(v)) return ('#' + v.slice(1).split('').map(x => x + x).join('')).toLowerCase()
    const rgb = /^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})/.exec(v)
    if (rgb) {
        const parts = rgb.slice(1, 4).map(Number)
        if (parts.every(n => n <= 255)) return '#' + parts.map(n => n.toString(16).padStart(2, '0')).join('')
    }
    return null
}

// Returns a TerminalColorScheme, or null when the palette lacks usable colours.
function toTabbyScheme (palette) {
    const fg = normalizeColor(palette.foreground)
    const bg = normalizeColor(palette.background)
    if (!fg || !bg) return null
    const colors = ANSI_KEYS.map(k => normalizeColor(palette[k]))
    if (colors.some(x => !x)) return null
    const scheme = {
        name: SCHEME_NAME,
        foreground: fg,
        background: bg,
        cursor: normalizeColor(palette.cursor) || fg,
        cursorAccent: bg,
        colors,
    }
    const selection = normalizeColor(palette.selection_background)
    const selectionForeground = normalizeColor(palette.selection_foreground)
    if (selection) scheme.selection = selection
    if (selectionForeground) scheme.selectionForeground = selectionForeground
    return scheme
}

function schemeFromToml (text, opts) {
    return toTabbyScheme(resolvePalette(parseColorsToml(text), opts))
}

function sameScheme (a, b) {
    if (!a || !b) return false
    const keys = ['name', 'foreground', 'background', 'cursor', 'cursorAccent', 'selection', 'selectionForeground']
    return keys.every(k => (a[k] || null) === (b[k] || null))
        && Array.isArray(a.colors) && Array.isArray(b.colors)
        && a.colors.length === b.colors.length
        && a.colors.every((x, i) => x === b.colors[i])
}

module.exports = { SCHEME_NAME, parseColorsToml, resolvePalette, mixColor, normalizeColor, toTabbyScheme, schemeFromToml, sameScheme }
