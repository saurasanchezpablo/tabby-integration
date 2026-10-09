'use strict'

// Omarchy's universal copy sends CTRL+Insert to windows tagged "terminal"
// (default/hypr/bindings/clipboard.lua); paste sends SHIFT+Insert, which Tabby
// already binds. Tabby only binds Ctrl-Shift-C for copy, so we add Ctrl-Insert.
const COPY_KEY = 'Ctrl-Insert'

function withKey (list, key) {
    const arr = Array.isArray(list) ? list.slice() : []
    return arr.some(x => x === key) ? arr : arr.concat([key])
}

function withoutKey (list, key) {
    return (Array.isArray(list) ? list : []).filter(x => x !== key)
}

// `fc-match monospace -f '%{family}\n'` -> "JetBrainsMono Nerd Font"
// (same as omarchy-font-current: first line, first comma-separated family).
function parseFontFamily (stdout) {
    const first = String(stdout || '').split('\n')[0].split(',')[0].trim()
    if (!first || first.length > 200 || /[\0\n;{}<>]/.test(first)) return null
    return first
}

function debounce (fn, ms) {
    let timer = null
    const wrapped = (...args) => {
        clearTimeout(timer)
        timer = setTimeout(() => { timer = null; fn(...args) }, ms)
    }
    wrapped.cancel = () => clearTimeout(timer)
    return wrapped
}

module.exports = { COPY_KEY, withKey, withoutKey, parseFontFamily, debounce }
