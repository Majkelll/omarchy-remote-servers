// Parsing, validation, and formatting for the Remote servers panel. Free of
// Qt so the QML plugin and the Node tests share one implementation.

var MAX_INPUT = 262144
var MAX_ROWS = 200
var MAX_FIELD = 512

var MIN_TIMEOUT = 2
var MAX_TIMEOUT = 60
var DEFAULT_TIMEOUT = 5

// The panel says all three of these, and they are three different things.
var OFFLINE_TEXT = "No connection, checks paused"
var PAUSED_TEXT = "Checks paused"
var NETWORK_MARKER = "#network"

var GLYPH = {
  server: "󰒋",
  serverOff: "󰒏",
  console: "󰆍",
  key: "󰌆",
  pause: "󰏤",
  play: "󰐊",
  offline: "󰖪",
  remove: "󰩺",
  add: "󰐕",
  edit: "󰏫",
  refresh: "󰑐",
  alert: "󰀦"
}

// Two copies: `test` on a /g regex is stateful, `replace` needs /g.
var CONTROL_CHARS = /[\x00-\x1f\x7f]/
var CONTROL_CHARS_ALL = /[\x00-\x1f\x7f]/g

function clean(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

// Control characters are stripped, not escaped. Every field ends up as one
// element of a \x1f-joined line (see statsEncode), so a stray \x1f or newline
// in one field would silently become a field boundary in another.
function clip(value) {
  return clean(value).replace(CONTROL_CHARS_ALL, "").slice(0, MAX_FIELD)
}

function toInt(value, fallback) {
  var parsed = parseInt(value, 10)
  return isFinite(parsed) ? parsed : fallback
}

function toFloat(value, fallback) {
  var parsed = parseFloat(value)
  return isFinite(parsed) ? parsed : fallback
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

// -------------------------------------------------------------------- hosts

// Loose on purpose: an ssh target is very often a bare ~/.ssh/config alias
// ("prod", "nas") rather than anything shaped like a hostname. Only what
// would actually break is refused.
function isPlausibleHost(host) {
  var text = clean(host)
  if (text === "") return false
  if (/\s/.test(text)) return false
  if (CONTROL_CHARS.test(text)) return false
  if (text.charAt(0) === "-") return false
  return true
}

function isSafeOptionValue(value) {
  var text = clean(value)
  if (text === "") return true
  if (CONTROL_CHARS.test(text)) return false
  return text.charAt(0) !== "-"
}

// ------------------------------------------------------------------ servers

function slug(text) {
  var base = clean(text).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
  return base === "" ? "server" : base
}

function uniqueId(seed, taken) {
  var used = taken || []
  var base = slug(seed)
  var id = base
  var suffix = 2
  while (used.indexOf(id) !== -1) {
    id = base + "-" + suffix
    suffix++
  }
  return id
}

function normalizePort(value) {
  var port = toInt(value, 0)
  return port >= 1 && port <= 65535 ? port : 0
}

function normalizeServer(raw, taken) {
  var source = raw || {}
  var host = clip(source.host)
  var server = {
    id: clean(source.id),
    name: clip(source.name) || host,
    host: host,
    port: normalizePort(source.port),
    user: isSafeOptionValue(source.user) ? clip(source.user) : "",
    identityFile: isSafeOptionValue(source.identityFile) ? clip(source.identityFile) : "",
    connectTimeoutSec: clamp(toInt(source.connectTimeoutSec, DEFAULT_TIMEOUT), MIN_TIMEOUT, MAX_TIMEOUT)
  }
  if (server.id === "" || (taken && taken.indexOf(server.id) !== -1))
    server.id = uniqueId(server.name || server.host, taken || [])
  return server
}

function normalizeServers(list) {
  var rows = Array.isArray(list) ? list : []
  var taken = []
  var out = []
  for (var i = 0; i < rows.length && out.length < MAX_ROWS; i++) {
    var server = normalizeServer(rows[i], taken)
    // Dropped here so no later stage has to ask.
    if (!isPlausibleHost(server.host)) continue
    taken.push(server.id)
    out.push(server)
  }
  return out
}

// servers.json is a file people edit by hand, so a broken one surfaces as a
// message rather than as an empty list.
function parseConfig(text) {
  var raw = String(text === undefined || text === null ? "" : text).slice(0, MAX_INPUT).trim()
  if (raw === "") return { servers: [], paused: false, error: "" }

  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (error) {
    return { servers: [], paused: false, error: "servers.json is not valid JSON" }
  }

  var list = Array.isArray(parsed)
    ? parsed
    : (parsed && Array.isArray(parsed.servers) ? parsed.servers : null)
  if (list === null) return { servers: [], paused: false, error: "servers.json has no servers array" }
  return {
    servers: normalizeServers(list),
    paused: !!(parsed && parsed.paused === true),
    error: ""
  }
}

function serializeConfig(servers, paused) {
  var rows = []
  var list = Array.isArray(servers) ? servers : []
  for (var i = 0; i < list.length; i++) {
    var server = list[i]
    rows.push({
      id: server.id,
      name: server.name,
      host: server.host,
      port: server.port,
      user: server.user,
      identityFile: server.identityFile,
      connectTimeoutSec: server.connectTimeoutSec
    })
  }
  return JSON.stringify({ version: 1, paused: paused === true, servers: rows }, null, 2) + "\n"
}

// Returns "" when the form can be saved, or the reason it cannot.
// `ignoreId` exempts the row being edited from the duplicate-name check.
function validate(nameRaw, hostRaw, portRaw, identityRaw, timeoutRaw, servers, ignoreId) {
  if (!isPlausibleHost(hostRaw)) {
    if (clean(hostRaw) === "") return "Enter a host, or an alias from ~/.ssh/config"
    return "That host can't be used as an ssh argument"
  }
  if (!isSafeOptionValue(nameRaw)) return "Name can't start with \"-\""
  var port = clean(portRaw)
  if (port !== "" && normalizePort(port) === 0) return "Port must be 1-65535"
  if (!isSafeOptionValue(identityRaw)) return "Identity file path can't start with \"-\""
  var timeout = clean(timeoutRaw)
  if (timeout !== "") {
    var seconds = toInt(timeout, -1)
    if (seconds < MIN_TIMEOUT || seconds > MAX_TIMEOUT)
      return "Timeout must be " + MIN_TIMEOUT + "-" + MAX_TIMEOUT + " seconds"
  }

  var name = clean(nameRaw) || clean(hostRaw)
  var list = Array.isArray(servers) ? servers : []
  for (var i = 0; i < list.length; i++) {
    if (list[i].id === ignoreId) continue
    if (list[i].name.toLowerCase() === name.toLowerCase()) return "That name is already on the list"
  }
  return ""
}

function buildServer(fields, servers) {
  var taken = []
  var list = Array.isArray(servers) ? servers : []
  for (var i = 0; i < list.length; i++) taken.push(list[i].id)
  return normalizeServer(fields, taken)
}

function updateServer(servers, id, patch) {
  var list = Array.isArray(servers) ? servers : []
  var out = []
  var taken = []
  for (var i = 0; i < list.length; i++) {
    if (list[i].id !== id) {
      out.push(list[i])
      taken.push(list[i].id)
      continue
    }
    var merged = {}
    for (var key in list[i]) merged[key] = list[i][key]
    for (var pkey in patch) merged[pkey] = patch[pkey]
    merged.id = id
    var normalized = normalizeServer(merged, taken)
    normalized.id = id
    taken.push(id)
    out.push(normalized)
  }
  return out
}

function withoutServer(servers, id) {
  var list = Array.isArray(servers) ? servers : []
  var out = []
  for (var i = 0; i < list.length; i++) if (list[i].id !== id) out.push(list[i])
  return out
}

function findServer(servers, id) {
  var list = Array.isArray(servers) ? servers : []
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
  return null
}

// Names are unique per validate(), so the panel can find the row it just
// added without addServer having to return an id alongside its error string.
function indexOfName(servers, name) {
  var list = Array.isArray(servers) ? servers : []
  var wanted = clean(name).toLowerCase()
  if (wanted === "") return -1
  for (var i = 0; i < list.length; i++) if (clean(list[i].name).toLowerCase() === wanted) return i
  return -1
}

// Only the parts that differ from ssh's own defaults.
function targetLabel(server) {
  if (!server) return ""
  var text = server.host
  if (server.port > 0) text += ":" + server.port
  if (server.user) text = server.user + "@" + text
  return text
}

// One argv element per field, so BarWidget hands these to execDetached
// without building a shell string. "" means "let ssh decide".
function connectArgs(server) {
  return [
    server.host,
    server.port > 0 ? String(server.port) : "",
    server.user || "",
    server.identityFile || "",
    String(server.connectTimeoutSec || DEFAULT_TIMEOUT)
  ]
}

// One \x1f-joined argv element per server for the batched stats-all call.
function statsEncode(server) {
  return [server.id].concat(connectArgs(server)).join("\x1f")
}

// -------------------------------------------------------------------- stats

// The connectivity line stats-all emits before it probes anything. Absent or
// unreadable means "assume online": a probe that could not run must never be
// the reason a real outage goes unreported.
function parseNetwork(raw) {
  var lines = clean(raw).slice(0, MAX_INPUT).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].split("\x1f")
    if (clean(f[0]) !== NETWORK_MARKER) continue
    var state = clean(f[1])
    return {
      known: state === "online" || state === "offline",
      online: state !== "offline",
      detail: clip(f.length > 2 ? f[2] : "")
    }
  }
  return { known: false, online: true, detail: "" }
}

// The probe can be wrong: a server on the LAN answers with no internet at all,
// and a captive portal answers everything. A server that replied is proof
// enough, so a reachable server anywhere in the batch overrules the probe.
function batchWasOffline(network, statsById) {
  if (!network || !network.known || network.online) return false
  var stats = statsById || {}
  for (var id in stats) if (stats[id].reachable) return false
  return true
}

// stats-all prints one line per server:
//   id \x1f ok \x1f hostname \x1f cores \x1f load1 \x1f memTotalKB \x1f memAvailKB \x1f uptimeSec
//   id \x1f err \x1f code
// A short line is a truncated read, not a result, so it is dropped whole.
function parseStatsAll(raw) {
  var byId = {}
  var kept = 0
  var lines = clean(raw).slice(0, MAX_INPUT).split("\n")
  for (var i = 0; i < lines.length && kept < MAX_ROWS; i++) {
    if (!lines[i]) continue
    var f = lines[i].split("\x1f")
    if (f.length < 3) continue
    var id = clip(f[0])
    if (id === "" || id === NETWORK_MARKER) continue

    if (f[1] === "ok" && f.length >= 8) {
      byId[id] = {
        reachable: true,
        error: "",
        hostname: clip(f[2]),
        cores: Math.max(1, toInt(f[3], 1)),
        load1: Math.max(0, toFloat(f[4], 0)),
        memTotalKB: Math.max(0, toInt(f[5], 0)),
        memAvailKB: Math.max(0, toInt(f[6], 0)),
        uptimeSec: Math.max(0, toInt(f[7], 0))
      }
    } else {
      byId[id] = { reachable: false, error: clip(f[2] || "unreachable") }
    }
    kept++
  }
  return byId
}

// Normalized against the core count, so it reads as "how loaded is this
// machine" rather than as a figure that means nothing on its own.
function loadPercent(stat) {
  if (!stat || !stat.reachable) return 0
  return (stat.load1 / Math.max(1, stat.cores)) * 100
}

function formatPercent(value) {
  return Math.round(Math.max(0, Number(value) || 0)) + "%"
}

// Both halves in the total's unit, so the pair reads as one fraction.
function formatMemPair(usedKB, totalKB) {
  var total = Math.max(0, Number(totalKB) || 0) * 1024
  var used = Math.max(0, Number(usedKB) || 0) * 1024
  var units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var unit = 0
  while (total >= 1024 && unit < units.length - 1) {
    total /= 1024
    used /= 1024
    unit++
  }
  var precision = total >= 100 || unit === 0 ? 0 : 1
  return used.toFixed(precision) + " / " + total.toFixed(precision) + " " + units[unit]
}

function formatUptime(seconds) {
  var s = Math.max(0, Number(seconds) || 0)
  var days = Math.floor(s / 86400)
  var hours = Math.floor((s % 86400) / 3600)
  var minutes = Math.floor((s % 3600) / 60)
  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + minutes + "m"
  if (minutes > 0) return minutes + "m"
  return "just booted"
}

function rowStatLine(stat) {
  if (!stat) return ""
  if (!stat.reachable) return errorText(stat.error)
  var memUsedKB = Math.max(0, stat.memTotalKB - stat.memAvailKB)
  return "load " + formatPercent(loadPercent(stat)) +
    " · RAM " + formatMemPair(memUsedKB, stat.memTotalKB) +
    " · up " + formatUptime(stat.uptimeSec)
}

// The only place that decides a server changed state. A server with no
// previous reading transitions into nothing: the first answer after the popup
// opens is not news, it is the baseline.
function transitions(previousById, nextById, servers) {
  var before = previousById || {}
  var after = nextById || {}
  var list = Array.isArray(servers) ? servers : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var id = list[i].id
    var was = before[id]
    var now = after[id]
    if (!was || !now) continue
    if (was.reachable === now.reachable) continue
    out.push({
      id: id,
      name: list[i].name,
      target: targetLabel(list[i]),
      transition: now.reachable ? "up" : "down",
      reason: now.reachable ? "" : errorText(now.error)
    })
  }
  return out
}

function needsAttention(stat) {
  return !!stat && stat.reachable === false
}

function summary(servers, statsById, paused, offline) {
  var list = Array.isArray(servers) ? servers : []
  if (list.length === 0) return "No servers yet"
  if (paused) return list.length + (list.length === 1 ? " server" : " servers") + ", " + PAUSED_TEXT.toLowerCase()
  if (offline) return OFFLINE_TEXT
  var stats = statsById || {}
  var down = 0
  var known = 0
  for (var i = 0; i < list.length; i++) {
    var stat = stats[list[i].id]
    if (!stat) continue
    known++
    if (!stat.reachable) down++
  }
  var text = list.length + (list.length === 1 ? " server" : " servers")
  if (down > 0) text += " · " + down + " unreachable"
  else if (known > 0) text += " · all reachable"
  return text
}

// While paused or offline every reading is a memory rather than a reading, so
// nothing is reported as needing attention on the strength of one.
function attentionCount(servers, statsById, paused, offline) {
  if (paused || offline) return 0
  var list = Array.isArray(servers) ? servers : []
  var stats = statsById || {}
  var n = 0
  for (var i = 0; i < list.length; i++) if (needsAttention(stats[list[i].id])) n++
  return n
}

// The helper speaks in short codes so the panel owns the wording.
function errorText(code) {
  switch (clean(code)) {
    case "": return ""
    case "ssh-missing": return "ssh is not installed"
    case "timeout-missing": return "coreutils timeout is not installed"
    case "keygen-missing": return "ssh-keygen is not installed"
    case "copy-id-missing": return "ssh-copy-id is not installed"
    case "session-missing": return "The plugin's terminal helper is missing"
    case "no-host": return "No host given"
    case "auth-failed": return "Key-based auth not set up for this host"
    case "unreachable": return "Could not reach the host"
    case "timeout": return "Timed out connecting"
    case "terminal-missing": return "No terminal launcher found"
    default: return clean(code)
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_INPUT: MAX_INPUT,
    MAX_ROWS: MAX_ROWS,
    MAX_FIELD: MAX_FIELD,
    MIN_TIMEOUT: MIN_TIMEOUT,
    MAX_TIMEOUT: MAX_TIMEOUT,
    DEFAULT_TIMEOUT: DEFAULT_TIMEOUT,
    OFFLINE_TEXT: OFFLINE_TEXT,
    PAUSED_TEXT: PAUSED_TEXT,
    NETWORK_MARKER: NETWORK_MARKER,
    GLYPH: GLYPH,
    clean: clean,
    clip: clip,
    isPlausibleHost: isPlausibleHost,
    isSafeOptionValue: isSafeOptionValue,
    slug: slug,
    uniqueId: uniqueId,
    normalizePort: normalizePort,
    normalizeServer: normalizeServer,
    normalizeServers: normalizeServers,
    parseConfig: parseConfig,
    serializeConfig: serializeConfig,
    validate: validate,
    buildServer: buildServer,
    updateServer: updateServer,
    withoutServer: withoutServer,
    findServer: findServer,
    indexOfName: indexOfName,
    targetLabel: targetLabel,
    connectArgs: connectArgs,
    statsEncode: statsEncode,
    parseNetwork: parseNetwork,
    batchWasOffline: batchWasOffline,
    parseStatsAll: parseStatsAll,
    transitions: transitions,
    loadPercent: loadPercent,
    formatPercent: formatPercent,
    formatMemPair: formatMemPair,
    formatUptime: formatUptime,
    rowStatLine: rowStatLine,
    needsAttention: needsAttention,
    summary: summary,
    attentionCount: attentionCount,
    errorText: errorText
  }
}
