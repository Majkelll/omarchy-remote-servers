import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.majkelll.omarchy-remote-servers"

  readonly property string ctlPath: String(Qt.resolvedUrl("bin/omarchy-remote-servers-ctl")).replace(/^file:\/\//, "")
  readonly property string probePath: String(Qt.resolvedUrl("bin/omarchy-remote-servers-probe.sh")).replace(/^file:\/\//, "")

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/omarchy-remote-servers"
  readonly property string configPath: configDir + "/servers.json"

  property var servers: []
  property var stats: ({})
  property string configError: ""
  property string actionError: ""

  // Set by the `restart` IPC call. The panel watches it and puts the
  // confirmation on screen itself, so a keybinding cannot skip the dialog
  // that a click on the row's own Restart button goes through.
  property string pendingRestart: ""

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property int attentionCount: Model.attentionCount(root.servers, root.stats)

  readonly property int statsRefreshSec: Math.max(10, Number(root.setting("statsRefreshSec", 20)) || 20)

  readonly property string tooltip: root.configError !== ""
    ? ("servers.json: " + root.configError)
    : Model.summary(root.servers, root.stats)

  readonly property var mirroredProperties: ["bar", "settings", "servers", "stats",
    "configError", "actionError", "pendingRestart"]

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    for (var i = 0; i < root.mirroredProperties.length; i++) {
      var name = root.mirroredProperties[i]
      if (name in target) target[name] = root[name]
    }
  }

  // ------------------------------------------------------------ persistence

  function loadConfig(raw) {
    var parsed = Model.parseConfig(raw)
    root.configError = parsed.error
    // A file that fails to parse keeps the servers already in memory.
    // Dropping them mid-edit is worse than showing the error over the list.
    if (parsed.error === "" || root.servers.length === 0) root.servers = parsed.servers
    root.injectPanel()
    Qt.callLater(root.refreshStats)
  }

  function writeConfig() {
    ensureDirProc.running = true
    configFile.setText(Model.serializeConfig(root.servers))
  }

  function saveServers(next) {
    root.servers = next
    root.configError = ""
    root.writeConfig()
    root.injectPanel()
  }

  // -------------------------------------------------------------------- CRUD

  function addServer(fields) {
    var problem = Model.validate(fields.name, fields.host, fields.port,
      fields.identityFile, fields.connectTimeoutSec, root.servers, "")
    if (problem !== "") return problem
    var server = Model.buildServer(fields, root.servers)
    root.saveServers(root.servers.concat([server]))
    Qt.callLater(function() { root.refreshOne(server.id) })
    return ""
  }

  function editServer(id, fields) {
    var problem = Model.validate(fields.name, fields.host, fields.port,
      fields.identityFile, fields.connectTimeoutSec, root.servers, id)
    if (problem !== "") return problem
    root.saveServers(Model.updateServer(root.servers, id, fields))
    Qt.callLater(function() { root.refreshOne(id) })
    return ""
  }

  function removeServer(id) {
    root.saveServers(Model.withoutServer(root.servers, id))
    var next = {}
    for (var key in root.stats) if (key !== id) next[key] = root.stats[key]
    root.stats = next
    root.injectPanel()
  }

  // ----------------------------------------------------------------- actions

  function connect(id) {
    var server = Model.findServer(root.servers, id)
    if (!server) return
    root.actionError = ""
    Quickshell.execDetached([root.ctlPath, "connect"].concat(Model.connectArgs(server)))
  }

  function restart(id) {
    var server = Model.findServer(root.servers, id)
    if (!server) return
    root.actionError = ""
    Quickshell.execDetached([root.ctlPath, "restart"].concat(Model.restartArgs(server)))
  }

  // Generates a key if there isn't one and copies it to the server. The
  // account's existing password is asked for once, in the terminal, by
  // ssh-copy-id itself. Nothing here ever sees it.
  function setupKey(id) {
    var server = Model.findServer(root.servers, id)
    if (!server) return
    root.actionError = ""
    Quickshell.execDetached([root.ctlPath, "setup-key"].concat(Model.connectArgs(server)))
  }

  function requestRestart(id) {
    root.pendingRestart = id
    root.injectPanel()
    root.open()
  }

  // Called by the panel once the confirmation is on screen, so the same
  // request cannot re-open the dialog on every mirror tick.
  function clearPendingRestart() {
    root.pendingRestart = ""
    root.injectPanel()
  }

  function serverByName(name) {
    for (var i = 0; i < root.servers.length; i++) {
      if (root.servers[i].id === name || root.servers[i].name === name) return root.servers[i]
    }
    return null
  }

  function connectByName(name) {
    var server = root.serverByName(name)
    if (server) root.connect(server.id)
  }

  function restartByName(name) {
    var server = root.serverByName(name)
    if (server) root.requestRestart(server.id)
  }

  function setupKeyByName(name) {
    var server = root.serverByName(name)
    if (server) root.setupKey(server.id)
  }

  // ------------------------------------------------------------------- stats

  function refreshStats() {
    root.refreshServers(root.servers)
  }

  function refreshOne(id) {
    var server = Model.findServer(root.servers, id)
    if (server) root.refreshServers([server])
  }

  // One helper call for every server, probed in parallel there: ssh round
  // trips are network-bound, so five servers one after another would mean
  // waiting out five timeouts instead of one.
  function refreshServers(list) {
    if (!root.opened || list.length === 0 || statsProc.running) return
    var args = [root.ctlPath, "stats-all", root.probePath]
    for (var i = 0; i < list.length; i++) args.push(Model.statsEncode(list[i]))
    statsProc.command = args
    statsProc.running = true
  }

  function applyStats(text, code) {
    if (code !== 0 && text === "") return
    var parsed = Model.parseStatsAll(text)
    var next = {}
    for (var key in root.stats) next[key] = root.stats[key]
    for (var id in parsed) next[id] = parsed[id]
    root.stats = next
    root.injectPanel()
  }

  // --------------------------------------------------------------- lifecycle

  function open() {
    if (panelLoader.item) panelLoader.item.open()
    root.refreshStats()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  onBarChanged: root.injectPanel()
  onSettingsChanged: root.injectPanel()
  onOpenedChanged: if (root.opened) root.refreshStats()

  Component.onCompleted: {
    ensureDirProc.running = true
    Qt.callLater(configFile.reload)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Timer {
    interval: root.statsRefreshSec * 1000
    repeat: true
    running: root.opened
    onTriggered: root.refreshStats()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadConfig(text())
    // No file yet is the first-run state, not an error.
    onLoadFailed: root.loadConfig("")
  }

  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", root.configDir]
  }

  Process {
    id: statsProc
    property string outText: ""
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: statsProc.outText = text }
    onExited: function(code) {
      root.applyStats(statsProc.outText, code)
      statsProc.outText = ""
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.majkelll.omarchy-remote-servers"
    function list(): string { return Model.summary(root.servers, root.stats) }
    function refresh(): void { root.refreshStats() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function connect(name: string): void { root.connectByName(name) }
    function setupKey(name: string): void { root.setupKeyByName(name) }
    // Asks rather than restarts, same as a click on the row's own button.
    function restart(name: string): void { root.restartByName(name) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.attentionCount > 0 ? Model.GLYPH.serverOff : Model.GLYPH.server
    fontSize: Style.font.icon
    active: root.attentionCount > 0 || root.configError !== ""
    dimmed: root.servers.length === 0 && root.configError === ""
    tooltipText: root.tooltip
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) {
        root.refreshStats()
        return
      }
      root.toggle()
    }
  }
}
