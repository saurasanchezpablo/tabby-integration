// Pure logic for the Tabby bar widget. No QML imports, so node can test it
// (tests/model.test.js). Glyphs are built from codepoints: private-use
// characters written literally get stripped by some tools.

var G = function (cp) { return String.fromCodePoint(cp) }

var ICONS = {
  terminal: G(0xF489),   // nf-oct-terminal
  shell: G(0xF120),      // nf-fa-terminal
  server: G(0xF233),     // nf-fa-server (ssh, telnet)
  serial: G(0xF1E6),     // nf-fa-plug
  plus: G(0xF067),       // nf-fa-plus
  window: G(0xF2D0),     // nf-fa-window_maximize
  dropdown: G(0xF0D7),   // nf-fa-caret_down
  focus: G(0xF06E),      // nf-fa-eye
  palette: G(0xF1FC),    // nf-fa-paint_brush
  font: G(0xF031),       // nf-fa-font
  refresh: G(0xF021),    // nf-fa-refresh
  warning: G(0xF071),    // nf-fa-warning
  check: G(0xF00C)       // nf-fa-check
}

var MAX_PROFILES = 8

function asObject(v) {
  return v && typeof v === "object" && !Array.isArray(v) ? v : {}
}

// Parse `omarchy-tabby status --json`; never throws.
function parseStatus(text) {
  try {
    var s = JSON.parse(String(text || ""))
    return asObject(s)
  } catch (e) {
    return {}
  }
}

function tabby(status) { return asObject(asObject(status).tabby) }
function companion(status) { return asObject(asObject(status).companion) }

function running(status) { return tabby(status).running === true }

function problem(status) {
  return companion(status).needsRestart === true || tabby(status).installed === false
}

function tabCount(status) {
  var n = Number(asObject(status).tabs)
  return isFinite(n) && n > 0 ? Math.floor(n) : 0
}

function barText(status, showTabs) {
  var n = tabCount(status)
  if (showTabs && running(status) && n > 0) return ICONS.terminal + " " + n
  return ICONS.terminal
}

// Hero subtitle, upper-cased by the view.
function statusLine(status) {
  var t = tabby(status)
  var c = companion(status)
  if (t.installed === false) return "Tabby is not installed"
  if (c.needsRestart) return "Restart Tabby to load the integration"
  if (!t.running) return "Not running"
  var n = tabCount(status)
  var parts = []
  if (c.loaded) parts.push(n + (n === 1 ? " tab" : " tabs"))
  var w = Number(t.windows) || 0
  if (w > 0) parts.push(w + (w === 1 ? " window" : " windows"))
  if (t.dropdown) parts.push("dropdown")
  return parts.join(" · ") || "Running"
}

function syncLabel(state, detail) {
  switch (state) {
  case "synced": return detail ? "Synced · " + detail : "Synced"
  case "paused": return "Paused (changed in Tabby)"
  case "off": return "Off"
  case "error": return "Unavailable"
  default: return "—"
  }
}

function profileIcon(type) {
  switch (String(type || "")) {
  case "local": return ICONS.shell
  case "ssh":
  case "telnet": return ICONS.server
  case "serial": return ICONS.serial
  default: return ICONS.terminal
  }
}

// User profiles first, then built-in local shells; at most MAX_PROFILES.
function visibleProfiles(status) {
  var list = asObject(status).profiles
  if (!Array.isArray(list)) return []
  var clean = list.filter(function (p) {
    return p && typeof p === "object" && typeof p.id === "string" && p.id !== "" && typeof p.name === "string"
  })
  var user = clean.filter(function (p) { return !p.builtin })
  var builtinLocal = clean.filter(function (p) { return p.builtin && p.type === "local" })
  return user.concat(builtinLocal).slice(0, MAX_PROFILES)
}

// Schema entries (from `omarchy-tabby settings list --json`) that are switches.
function toggleSettings(list) {
  if (!Array.isArray(list)) return []
  return list.filter(function (s) { return s && s.type === "boolean" && typeof s.key === "string" })
}

function enumSetting(list, key) {
  if (!Array.isArray(list)) return null
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].key === key && list[i].type === "enum") return list[i]
  }
  return null
}

function clampInterval(v, fallback) {
  var n = Number(v)
  if (!isFinite(n)) n = fallback
  return Math.max(2, Math.min(60, Math.round(n)))
}

if (typeof module !== "undefined") {
  module.exports = {
    ICONS: ICONS,
    MAX_PROFILES: MAX_PROFILES,
    parseStatus: parseStatus,
    running: running,
    problem: problem,
    tabCount: tabCount,
    barText: barText,
    statusLine: statusLine,
    syncLabel: syncLabel,
    profileIcon: profileIcon,
    visibleProfiles: visibleProfiles,
    toggleSettings: toggleSettings,
    enumSetting: enumSetting,
    clampInterval: clampInterval
  }
}
