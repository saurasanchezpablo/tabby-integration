'use strict'
// Shared settings: ~/.config/omarchy-tabby/settings.json, written by the
// omarchy-tabby CLI, read here. Unknown keys and wrong types fall back to the
// schema defaults, so a hand-edited or corrupt file can never break Tabby.

const SCHEMA = require('./settings-schema.json')

function defaults () {
    const out = {}
    for (const [key, spec] of Object.entries(SCHEMA)) out[key] = spec.default
    return out
}

function validValue (spec, value) {
    if (spec.type === 'boolean') return typeof value === 'boolean'
    if (spec.type === 'enum') return typeof value === 'string' && spec.options.includes(value)
    return false
}

function normalize (raw) {
    const out = defaults()
    if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
        for (const [key, spec] of Object.entries(SCHEMA)) {
            if (Object.prototype.hasOwnProperty.call(raw, key) && validValue(spec, raw[key])) {
                out[key] = raw[key]
            }
        }
    }
    return out
}

function parse (text) {
    try {
        return normalize(JSON.parse(text))
    } catch {
        return defaults()
    }
}

function load (fs, file) {
    try {
        return parse(fs.readFileSync(file, 'utf8'))
    } catch {
        return defaults()
    }
}

module.exports = { SCHEMA, defaults, normalize, parse, load, validValue }
