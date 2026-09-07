const { describe, test } = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

const US = "\x1f"

describe("clip", () => {
  test("trims and truncates to MAX_FIELD", () => {
    assert.equal(Model.clip("  spaced  "), "spaced")
    assert.equal(Model.clip("x".repeat(Model.MAX_FIELD + 50)).length, Model.MAX_FIELD)
  })

  test("strips control characters that would forge a field boundary", () => {
    assert.equal(Model.clip("a" + US + "b"), "ab")
    assert.equal(Model.clip("a\nb\tc\x00d\x7fe"), "abcde")
  })

  test("accepts undefined and null", () => {
    assert.equal(Model.clip(undefined), "")
    assert.equal(Model.clip(null), "")
  })
})

describe("isPlausibleHost", () => {
  test("accepts hostnames, addresses, and bare ~/.ssh/config aliases", () => {
    assert.equal(Model.isPlausibleHost("prod.example.com"), true)
    assert.equal(Model.isPlausibleHost("prod"), true)
    assert.equal(Model.isPlausibleHost("192.168.1.10"), true)
    assert.equal(Model.isPlausibleHost("2001:db8::1"), true)
  })

  test("rejects empty and whitespace", () => {
    assert.equal(Model.isPlausibleHost(""), false)
    assert.equal(Model.isPlausibleHost("   "), false)
    assert.equal(Model.isPlausibleHost("has space"), false)
  })

  test("rejects a value ssh would read as a flag", () => {
    assert.equal(Model.isPlausibleHost("-oProxyCommand=evil"), false)
  })

  // \x1f is not \s, so the whitespace check alone let it through and it
  // became a field boundary in statsEncode.
  test("rejects control characters", () => {
    assert.equal(Model.isPlausibleHost("a" + US + "b"), false)
    assert.equal(Model.isPlausibleHost("a\x00b"), false)
  })
})

describe("isSafeOptionValue", () => {
  test("accepts empty and ordinary paths", () => {
    assert.equal(Model.isSafeOptionValue(""), true)
    assert.equal(Model.isSafeOptionValue("~/.ssh/id_ed25519"), true)
  })

  test("rejects a leading dash and control characters", () => {
    assert.equal(Model.isSafeOptionValue("-oProxyCommand=evil"), false)
    assert.equal(Model.isSafeOptionValue("root" + US + "x"), false)
    assert.equal(Model.isSafeOptionValue("root\nx"), false)
  })
})

describe("slug and uniqueId", () => {
  test("slugs to lowercase dashes with a fallback", () => {
    assert.equal(Model.slug("Prod Web!"), "prod-web")
    assert.equal(Model.slug("---"), "server")
    assert.equal(Model.slug(""), "server")
  })

  test("suffixes until the id is free", () => {
    assert.equal(Model.uniqueId("prod", []), "prod")
    assert.equal(Model.uniqueId("prod", ["prod"]), "prod-2")
    assert.equal(Model.uniqueId("prod", ["prod", "prod-2"]), "prod-3")
  })
})

describe("normalizePort", () => {
  test("keeps a port in range and zeroes anything else", () => {
    assert.equal(Model.normalizePort("22"), 22)
    assert.equal(Model.normalizePort(65535), 65535)
    assert.equal(Model.normalizePort("0"), 0)
    assert.equal(Model.normalizePort("70000"), 0)
    assert.equal(Model.normalizePort("-1"), 0)
    assert.equal(Model.normalizePort(""), 0)
    assert.equal(Model.normalizePort("abc"), 0)
  })
})

describe("normalizeServer", () => {
  test("fills in every default from a name and a host", () => {
    const s = Model.normalizeServer({ name: "Prod", host: "prod.example.com" }, [])
    assert.equal(s.id, "prod")
    assert.equal(s.port, 0)
    assert.equal(s.user, "")
    assert.equal(s.identityFile, "")
    assert.equal(s.connectTimeoutSec, Model.DEFAULT_TIMEOUT)
  })

  test("falls back to the host when no name is given", () => {
    assert.equal(Model.normalizeServer({ host: "nas" }, []).name, "nas")
  })

  test("drops a user or identity file that would be read as an ssh flag", () => {
    const s = Model.normalizeServer({
      name: "x", host: "h", user: "-oProxyCommand=evil", identityFile: "-i/evil"
    }, [])
    assert.equal(s.user, "")
    assert.equal(s.identityFile, "")
  })

  test("clamps the timeout into range", () => {
    assert.equal(Model.normalizeServer({ host: "h", connectTimeoutSec: 1 }, []).connectTimeoutSec, Model.MIN_TIMEOUT)
    assert.equal(Model.normalizeServer({ host: "h", connectTimeoutSec: 999 }, []).connectTimeoutSec, Model.MAX_TIMEOUT)
    assert.equal(Model.normalizeServer({ host: "h", connectTimeoutSec: "junk" }, []).connectTimeoutSec, Model.DEFAULT_TIMEOUT)
  })

  test("gives a colliding id a fresh one", () => {
    assert.equal(Model.normalizeServer({ id: "web", name: "web", host: "h" }, ["web"]).id, "web-2")
  })
})

describe("normalizeServers", () => {
  test("drops rows that could never be reached and keeps ids unique", () => {
    const servers = Model.normalizeServers([
      { name: "web", host: "web.example.com" },
      { name: "broken", host: "" },
      { name: "flag", host: "-oProxyCommand=evil" },
      { name: "web", host: "web2.example.com" }
    ])
    assert.equal(servers.length, 2)
    assert.equal(servers[0].id, "web")
    assert.notEqual(servers[1].id, servers[0].id)
  })

  test("caps the list at MAX_ROWS", () => {
    const many = []
    for (let i = 0; i < Model.MAX_ROWS + 25; i++) many.push({ name: "h" + i, host: "h" + i })
    assert.equal(Model.normalizeServers(many).length, Model.MAX_ROWS)
  })

  test("treats anything that is not an array as empty", () => {
    assert.deepEqual(Model.normalizeServers(null), [])
    assert.deepEqual(Model.normalizeServers("nope"), [])
  })
})

describe("parseConfig", () => {
  const servers = Model.normalizeServers([
    { name: "web", host: "web.example.com" },
    { name: "nas", host: "nas" }
  ])

  test("round-trips what serializeConfig writes", () => {
    const parsed = Model.parseConfig(Model.serializeConfig(servers))
    assert.equal(parsed.error, "")
    assert.deepEqual(parsed.servers, servers)
  })

  test("carries the paused flag both ways", () => {
    assert.equal(Model.parseConfig(Model.serializeConfig(servers, true)).paused, true)
    assert.equal(Model.parseConfig(Model.serializeConfig(servers, false)).paused, false)
    // Anything but a literal true means running.
    assert.equal(Model.parseConfig('{"paused":"yes","servers":[]}').paused, false)
    assert.equal(Model.parseConfig('{"servers":[]}').paused, false)
  })

  test("reads a bare array as well as a {servers: []} document", () => {
    const parsed = Model.parseConfig(JSON.stringify([{ name: "web", host: "web.example.com" }]))
    assert.equal(parsed.error, "")
    assert.equal(parsed.servers.length, 1)
  })

  test("an empty file is the first-run state, not an error", () => {
    assert.deepEqual(Model.parseConfig(""), { servers: [], paused: false, error: "" })
    assert.deepEqual(Model.parseConfig("   \n"), { servers: [], paused: false, error: "" })
  })

  test("reports why a hand-edited file could not be read", () => {
    assert.equal(Model.parseConfig("{not json").error, "servers.json is not valid JSON")
    assert.equal(Model.parseConfig("{}").error, "servers.json has no servers array")
    assert.equal(Model.parseConfig("42").error, "servers.json has no servers array")
  })

  test("never reads more than MAX_INPUT", () => {
    // Valid JSON only within the first MAX_INPUT bytes; the slice makes it invalid.
    const padded = '{"servers":[]}' + " ".repeat(Model.MAX_INPUT) + "trailing garbage"
    assert.equal(Model.parseConfig(padded).error, "")
  })
})

describe("serializeConfig", () => {
  test("writes a versioned document ending in a newline", () => {
    const text = Model.serializeConfig(Model.normalizeServers([{ name: "web", host: "w" }]))
    assert.equal(text.endsWith("\n"), true)
    const doc = JSON.parse(text)
    assert.equal(doc.version, 1)
    assert.deepEqual(Object.keys(doc.servers[0]).sort(), [
      "connectTimeoutSec", "host", "id", "identityFile", "name", "port", "user"
    ])
  })

  test("treats anything that is not an array as empty", () => {
    assert.deepEqual(JSON.parse(Model.serializeConfig(undefined)).servers, [])
  })
})

describe("validate", () => {
  const existing = [{ id: "web", name: "web" }]

  test("accepts a name and a host on their own", () => {
    assert.equal(Model.validate("web", "web.example.com", "", "", "", [], ""), "")
  })

  test("asks for a host when there is none", () => {
    assert.match(Model.validate("web", "", "", "", "", [], ""), /^Enter a host/)
  })

  test("refuses a host that is not usable as an ssh argument", () => {
    assert.match(Model.validate("web", "-oProxyCommand=x", "", "", "", [], ""), /can't be used/)
    assert.match(Model.validate("web", "a" + US + "b", "", "", "", [], ""), /can't be used/)
  })

  test("refuses a name or identity file that would be read as a flag", () => {
    assert.match(Model.validate("-name", "host", "", "", "", [], ""), /Name can't start/)
    assert.match(Model.validate("web", "host", "", "-i/evil", "", [], ""), /Identity file/)
  })

  test("bounds the port and the timeout", () => {
    assert.match(Model.validate("web", "host", "999999", "", "", [], ""), /^Port/)
    assert.match(Model.validate("web", "host", "0", "", "", [], ""), /^Port/)
    assert.match(Model.validate("web", "host", "", "", "999", [], ""), /^Timeout/)
    assert.match(Model.validate("web", "host", "", "", "1", [], ""), /^Timeout/)
    assert.equal(Model.validate("web", "host", "22", "", "5", [], ""), "")
  })

  test("refuses a duplicate name, case-insensitively", () => {
    assert.match(Model.validate("WEB", "host2", "", "", "", existing, ""), /already/)
  })

  test("does not let a row collide with itself while being edited", () => {
    assert.equal(Model.validate("web", "host2", "", "", "", existing, "web"), "")
  })

  test("falls back to the host for the duplicate check when no name is typed", () => {
    assert.match(Model.validate("", "web", "", "", "", existing, ""), /already/)
  })
})

describe("CRUD", () => {
  test("builds, renames, and removes without disturbing the rest", () => {
    let list = []
    list = list.concat([Model.buildServer({ name: "a", host: "a.example.com" }, list)])
    list = list.concat([Model.buildServer({ name: "b", host: "b.example.com" }, list)])
    assert.equal(list.length, 2)

    list = Model.updateServer(list, "a", { name: "a-renamed" })
    assert.equal(Model.findServer(list, "a").name, "a-renamed")
    assert.equal(Model.findServer(list, "a").host, "a.example.com")
    assert.equal(Model.findServer(list, "b").name, "b")

    list = Model.withoutServer(list, "b")
    assert.equal(list.length, 1)
    assert.equal(Model.findServer(list, "b"), null)
  })

  test("an edit keeps the id even when the name that seeded it changes", () => {
    const list = Model.updateServer(
      [Model.normalizeServer({ name: "a", host: "a" }, [])], "a", { name: "totally-different" })
    assert.equal(list[0].id, "a")
  })

  test("finds the row just added by the name it was added under", () => {
    const list = Model.normalizeServers([
      { name: "web", host: "w" }, { name: "NAS", host: "n" }
    ])
    assert.equal(Model.indexOfName(list, "NAS"), 1)
    assert.equal(Model.indexOfName(list, "nas"), 1)
    assert.equal(Model.indexOfName(list, "  web  "), 0)
    assert.equal(Model.indexOfName(list, "nope"), -1)
    assert.equal(Model.indexOfName(list, ""), -1)
    assert.equal(Model.indexOfName(null, "web"), -1)
  })

  test("updating or removing an unknown id is a no-op", () => {
    const list = [Model.normalizeServer({ name: "a", host: "a" }, [])]
    assert.deepEqual(Model.updateServer(list, "nope", { name: "x" }), list)
    assert.deepEqual(Model.withoutServer(list, "nope"), list)
    assert.equal(Model.findServer(list, "nope"), null)
    assert.equal(Model.findServer(null, "a"), null)
  })
})

describe("ssh arguments", () => {
  const server = Model.normalizeServer({
    name: "prod", host: "prod.example.com", port: 2222, user: "deploy",
    identityFile: "~/.ssh/prod_key", connectTimeoutSec: 8
  }, [])

  test("labels a target with only what differs from ssh's defaults", () => {
    assert.equal(Model.targetLabel(server), "deploy@prod.example.com:2222")
    assert.equal(Model.targetLabel(Model.normalizeServer({ host: "nas" }, [])), "nas")
    assert.equal(Model.targetLabel(null), "")
  })

  test("passes one field per argv element", () => {
    assert.deepEqual(Model.connectArgs(server),
      ["prod.example.com", "2222", "deploy", "~/.ssh/prod_key", "8"])
  })

  test("a server relying on ~/.ssh/config carries no options at all", () => {
    assert.deepEqual(Model.connectArgs(Model.normalizeServer({ name: "nas", host: "nas" }, [])),
      ["nas", "", "", "", "5"])
  })

  test("encodes one \\x1f-joined element per server", () => {
    assert.equal(Model.statsEncode(server),
      [server.id, "prod.example.com", "2222", "deploy", "~/.ssh/prod_key", "8"].join(US))
  })

  // The helper reads these back with `IFS=\x1f read`, one line per server.
  test("no normalized field can add a field or a line to the encoding", () => {
    const hostile = Model.normalizeServer({
      id: "x", name: "n", host: "host", user: "root" + US + "extra", identityFile: "k\nmore"
    }, [])
    const encoded = Model.statsEncode(hostile)
    assert.equal(encoded.split(US).length, 6)
    assert.equal(encoded.includes("\n"), false)
  })
})

describe("parseStatsAll", () => {
  const okLine = ["srv1", "ok", "myhost", "8", "1.6", "16000000", "9000000", "93700"].join(US)
  const errLine = ["srv2", "err", "auth-failed"].join(US)
  const shortLine = ["srv3", "ok"].join(US)
  const byId = Model.parseStatsAll([okLine, errLine, shortLine, ""].join("\n"))

  test("reads a reachable server's whole reading", () => {
    assert.deepEqual(byId.srv1, {
      reachable: true, error: "", hostname: "myhost", cores: 8, load1: 1.6,
      memTotalKB: 16000000, memAvailKB: 9000000, uptimeSec: 93700
    })
  })

  test("reads an unreachable server's code", () => {
    assert.deepEqual(byId.srv2, { reachable: false, error: "auth-failed" })
  })

  test("drops a truncated line rather than half-parsing it", () => {
    assert.equal(Object.keys(byId).length, 2)
    assert.equal(byId.srv3, undefined)
  })

  test("floors nonsense numbers instead of propagating NaN", () => {
    const line = ["s", "ok", "h", "junk", "junk", "-5", "junk", "-9"].join(US)
    const stat = Model.parseStatsAll(line).s
    assert.equal(stat.cores, 1)
    assert.equal(stat.load1, 0)
    assert.equal(stat.memTotalKB, 0)
    assert.equal(stat.uptimeSec, 0)
  })

  test("an ok row missing fields is treated as an error row", () => {
    assert.equal(Model.parseStatsAll(["s", "ok", "h", "8"].join(US)).s.reachable, false)
  })

  test("caps at MAX_ROWS", () => {
    const lines = []
    for (let i = 0; i < Model.MAX_ROWS + 25; i++) lines.push(["s" + i, "err", "unreachable"].join(US))
    assert.equal(Object.keys(Model.parseStatsAll(lines.join("\n"))).length, Model.MAX_ROWS)
  })

  test("empty input is an empty map", () => {
    assert.deepEqual(Model.parseStatsAll(""), {})
    assert.deepEqual(Model.parseStatsAll(undefined), {})
  })
})

describe("parseNetwork", () => {
  test("reads the connectivity line stats-all prints first", () => {
    const line = ["#network", "online", "8.84"].join(US)
    assert.deepEqual(Model.parseNetwork(line), { known: true, online: true, detail: "8.84" })
  })

  test("reads an offline verdict and its reason", () => {
    const line = ["#network", "offline", "no route to the internet"].join(US)
    assert.deepEqual(Model.parseNetwork(line),
      { known: true, online: false, detail: "no route to the internet" })
  })

  // A probe that could not run must never be the reason an outage goes
  // unreported, so anything unreadable means "assume online".
  test("assumes online when the verdict is unknown or absent", () => {
    assert.deepEqual(Model.parseNetwork(["#network", "unknown", "ping is not installed"].join(US)),
      { known: false, online: true, detail: "ping is not installed" })
    assert.deepEqual(Model.parseNetwork(""), { known: false, online: true, detail: "" })
    assert.deepEqual(Model.parseNetwork("srv1" + US + "err" + US + "unreachable"),
      { known: false, online: true, detail: "" })
  })

  test("finds the line wherever it sits in the output", () => {
    const out = ["a" + US + "err" + US + "timeout", ["#network", "offline", "x"].join(US)].join("\n")
    assert.equal(Model.parseNetwork(out).online, false)
  })
})

describe("batchWasOffline", () => {
  const offline = { known: true, online: false, detail: "no route" }

  test("believes the probe when nothing answered", () => {
    assert.equal(Model.batchWasOffline(offline, { a: { reachable: false } }), true)
    assert.equal(Model.batchWasOffline(offline, {}), true)
  })

  // A server on the LAN answers with no internet at all, and that is proof
  // enough that the machine is not cut off.
  test("a server that answered overrules the probe", () => {
    assert.equal(Model.batchWasOffline(offline, { a: { reachable: false }, b: { reachable: true } }), false)
  })

  test("an online or unknown verdict is never an outage", () => {
    assert.equal(Model.batchWasOffline({ known: true, online: true }, {}), false)
    assert.equal(Model.batchWasOffline({ known: false, online: true }, {}), false)
    assert.equal(Model.batchWasOffline(null, {}), false)
  })
})

describe("transitions", () => {
  const servers = [{ id: "a", name: "web-01", host: "web-01.internal", port: 0, user: "" }]
  const up = { reachable: true }
  const down = { reachable: false, error: "timeout" }

  test("reports a server that stopped answering", () => {
    const out = Model.transitions({ a: up }, { a: down }, servers)
    assert.equal(out.length, 1)
    assert.equal(out[0].transition, "down")
    assert.equal(out[0].name, "web-01")
    assert.equal(out[0].target, "web-01.internal")
    assert.equal(out[0].reason, Model.errorText("timeout"))
  })

  test("reports a server that answered again", () => {
    const out = Model.transitions({ a: down }, { a: up }, servers)
    assert.equal(out.length, 1)
    assert.equal(out[0].transition, "up")
    assert.equal(out[0].reason, "")
  })

  test("says nothing when the state did not change", () => {
    assert.deepEqual(Model.transitions({ a: up }, { a: up }, servers), [])
    assert.deepEqual(Model.transitions({ a: down }, { a: down }, servers), [])
  })

  // The first answer after the popup opens is the baseline, not news.
  test("a first reading is never a transition", () => {
    assert.deepEqual(Model.transitions({}, { a: down }, servers), [])
    assert.deepEqual(Model.transitions({}, { a: up }, servers), [])
  })

  // The offline batch is never written to the stats, so the network coming
  // back can never read as every server recovering at once.
  test("a whole batch flipping at once is still reported per server", () => {
    const two = [{ id: "a", name: "a", host: "a" }, { id: "b", name: "b", host: "b" }]
    const out = Model.transitions({ a: up, b: up }, { a: down, b: down }, two)
    assert.equal(out.length, 2)
    assert.deepEqual(out.map(c => c.transition), ["down", "down"])
  })

  test("ignores a server that is no longer on the list", () => {
    assert.deepEqual(Model.transitions({ z: up }, { z: down }, servers), [])
    assert.deepEqual(Model.transitions(null, null, null), [])
  })
})

describe("formatting", () => {
  const stat = { reachable: true, cores: 8, load1: 1.6, memTotalKB: 16000000, memAvailKB: 9000000, uptimeSec: 93700 }

  test("normalizes load against the core count", () => {
    assert.equal(Math.round(Model.loadPercent(stat)), 20)
    assert.equal(Model.loadPercent({ reachable: false }), 0)
    assert.equal(Model.loadPercent(undefined), 0)
  })

  test("rounds a percentage and floors it at zero", () => {
    assert.equal(Model.formatPercent(19.6), "20%")
    assert.equal(Model.formatPercent(-5), "0%")
    assert.equal(Model.formatPercent("junk"), "0%")
  })

  test("shows used and total in the total's unit", () => {
    assert.equal(Model.formatMemPair(8000000, 16000000), "7.6 / 15.3 GiB")
    assert.equal(Model.formatMemPair(0, 0), "0 / 0 B")
    assert.equal(Model.formatMemPair(512, 1024), "0.5 / 1.0 MiB")
    // A used figure small enough to belong in another unit stays in the total's.
    assert.equal(Model.formatMemPair(900, 16000000), "0.0 / 15.3 GiB")
  })

  test("shows the two largest uptime units", () => {
    assert.equal(Model.formatUptime(93700), "1d 2h")
    assert.equal(Model.formatUptime(3700), "1h 1m")
    assert.equal(Model.formatUptime(120), "2m")
    assert.equal(Model.formatUptime(30), "just booted")
    assert.equal(Model.formatUptime(0), "just booted")
    assert.equal(Model.formatUptime(-1), "just booted")
  })

  test("builds the row line from a reading, and the reason from an error", () => {
    assert.equal(Model.rowStatLine(stat), "load 20% · RAM 6.7 / 15.3 GiB · up 1d 2h")
    assert.equal(Model.rowStatLine({ reachable: false, error: "auth-failed" }),
      "Key-based auth not set up for this host")
    assert.equal(Model.rowStatLine(undefined), "")
  })
})

describe("summary and attentionCount", () => {
  const up = { reachable: true }
  const down = { reachable: false, error: "timeout" }

  test("counts servers, and unreachable ones once anything is known", () => {
    assert.equal(Model.summary([], {}), "No servers yet")
    assert.equal(Model.summary([{ id: "a" }], {}), "1 server")
    assert.equal(Model.summary([{ id: "a" }, { id: "b" }], {}), "2 servers")
    assert.equal(Model.summary([{ id: "a" }, { id: "b" }], { a: up }), "2 servers · all reachable")
    assert.equal(Model.summary([{ id: "a" }, { id: "b" }], { a: up, b: down }), "2 servers · 1 unreachable")
  })

  test("says paused or offline instead of counting a stale reading", () => {
    assert.equal(Model.summary([{ id: "a" }], { a: down }, true, false), "1 server, checks paused")
    assert.equal(Model.summary([{ id: "a" }], { a: down }, false, true), Model.OFFLINE_TEXT)
    // Paused outranks offline: the checks stopped before the network did.
    assert.equal(Model.summary([{ id: "a" }], { a: down }, true, true), "1 server, checks paused")
    // With nothing on the list there is nothing to be paused about.
    assert.equal(Model.summary([], {}, true, true), "No servers yet")
  })

  test("counts only what actually needs attention", () => {
    assert.equal(Model.attentionCount([{ id: "a" }, { id: "b" }], { a: up, b: down }), 1)
    assert.equal(Model.attentionCount([{ id: "a" }], {}), 0)
    assert.equal(Model.attentionCount(null, null), 0)
  })

  test("nothing needs attention while paused or offline", () => {
    const servers = [{ id: "a" }, { id: "b" }]
    const stats = { a: down, b: down }
    assert.equal(Model.attentionCount(servers, stats), 2)
    assert.equal(Model.attentionCount(servers, stats, true, false), 0)
    assert.equal(Model.attentionCount(servers, stats, false, true), 0)
  })

  test("a server with no reading yet needs no attention", () => {
    assert.equal(Model.needsAttention(undefined), false)
    assert.equal(Model.needsAttention(up), false)
    assert.equal(Model.needsAttention(down), true)
  })
})

describe("errorText", () => {
  test("words every code the helper can emit", () => {
    for (const code of ["ssh-missing", "timeout-missing", "no-host", "auth-failed",
      "unreachable", "timeout", "terminal-missing"]) {
      const text = Model.errorText(code)
      assert.notEqual(text, "")
      assert.notEqual(text, code, `${code} should be worded, not passed through`)
    }
  })

  test("passes an unmapped code through rather than swallowing it", () => {
    assert.equal(Model.errorText(""), "")
    assert.equal(Model.errorText("something-unmapped"), "something-unmapped")
  })
})
