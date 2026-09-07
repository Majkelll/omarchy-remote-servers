import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.majkelll.omarchy-remote-servers"

  property var anchorItem: null
  property var hostWidget: null

  // Mirrored from BarWidget, which owns the list, its file, and every ssh call.
  property var servers: []
  property var stats: ({})
  property string configError: ""
  property string actionError: ""
  property bool paused: false
  property bool networkOffline: false
  property string networkDetail: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color faint: Qt.darker(foreground, 1.7)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Wide enough for the longest label in the form ("Identity file") to sit
  // on one line beside its input rather than running under it.
  readonly property real labelColumn: Style.space(110)
  readonly property real dotColumn: Style.space(18)
  readonly property real detailIndent: Style.spacing.rowPaddingX + dotColumn

  // "" means the form is adding; any other value means it is editing that
  // server's row. One form, one set of fields, reused for both.
  property string editingId: ""
  property string draftName: ""
  property string draftHost: ""
  property string draftPort: ""
  property string draftUser: ""
  property string draftIdentityFile: ""
  property string draftTimeoutSec: ""
  property string formError: ""
  property bool advancedOpen: false

  property string expandedId: ""

  property int selectedIndex: 0
  property bool cursorActive: false

  function colorForRow(server) {
    if (root.stale) return root.faint
    var stat = root.stats[server.id]
    if (Model.needsAttention(stat)) return Color.urgent
    if (stat && stat.reachable) return Color.accent
    return root.faint
  }

  function open() {
    root.controller.show()
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.controller.hide()
    root.cursorActive = false
    root.expandedId = ""
    root.cancelForm()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function togglePaused() {
    if (root.hostWidget) root.hostWidget.setPaused(!root.paused)
  }

  // Paused or offline, every reading on screen is a memory rather than a
  // reading, so no row is painted as though it just failed.
  readonly property bool stale: root.paused || root.networkOffline
  readonly property int attentionCount:
    Model.attentionCount(root.servers, root.stats, root.paused, root.networkOffline)
  readonly property bool alarmed: root.configError !== "" || root.attentionCount > 0

  function toggleExpanded(id) {
    if (root.editingId !== "") return
    root.expandedId = root.expandedId === id ? "" : id
  }

  function connectTo(id) {
    if (root.hostWidget) root.hostWidget.connect(id)
  }

  function setupKey(id) {
    if (root.hostWidget) root.hostWidget.setupKey(id)
  }

  // The one error the panel can offer a fix for rather than just report.
  function needsKey(stat) {
    return !!stat && stat.reachable === false && stat.error === "auth-failed"
  }

  // No reading yet counts too, so a server added a second ago already points
  // at the button it almost certainly needs next.
  function keyUnconfirmed(stat) {
    return !stat || root.needsKey(stat)
  }

  function removeServer(id) {
    if (root.expandedId === id) root.expandedId = ""
    if (root.editingId === id) root.cancelForm()
    if (root.hostWidget) root.hostWidget.removeServer(id)
  }

  function refresh() {
    if (root.hostWidget) root.hostWidget.refreshStats()
  }

  // ------------------------------------------------------------------ form

  function draftFields() {
    return {
      name: root.draftName,
      host: root.draftHost,
      port: root.draftPort,
      user: root.draftUser,
      identityFile: root.draftIdentityFile,
      connectTimeoutSec: root.draftTimeoutSec
    }
  }

  function startAdd() {
    root.editingId = ""
    root.draftName = ""
    root.draftHost = ""
    root.draftPort = ""
    root.draftUser = ""
    root.draftIdentityFile = ""
    root.draftTimeoutSec = ""
    root.formError = ""
    root.advancedOpen = false
  }

  function startEdit(server) {
    if (!server) return
    root.expandedId = ""
    root.editingId = server.id
    root.draftName = server.name
    root.draftHost = server.host
    root.draftPort = server.port > 0 ? String(server.port) : ""
    root.draftUser = server.user
    root.draftIdentityFile = server.identityFile
    root.draftTimeoutSec = String(server.connectTimeoutSec)
    root.formError = ""
    // Opens the section whenever something in it is already set, so nothing
    // already configured is hidden behind a collapsed disclosure.
    root.advancedOpen = server.port > 0 || server.user !== "" || server.identityFile !== ""
      || server.connectTimeoutSec !== Model.DEFAULT_TIMEOUT
  }

  function cancelForm() {
    root.startAdd()
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function submitForm() {
    if (!root.hostWidget) return
    var fields = root.draftFields()
    var adding = root.editingId === ""
    var problem = adding
      ? root.hostWidget.addServer(fields)
      : root.hostWidget.editServer(root.editingId, fields)
    if (problem !== "") {
      root.formError = problem
      return
    }
    // A new server is opened on the spot: setting up its key is the next
    // thing it needs, and that button lives one row down.
    var addedAt = adding
      ? Model.indexOfName(root.servers, Model.clean(fields.name) || Model.clean(fields.host))
      : -1
    root.startAdd()
    if (addedAt >= 0) {
      root.takeCursor(addedAt)
      root.expandedId = root.servers[addedAt].id
    }
  }

  // A server can vanish from under an open form or row: servers.json is a
  // file people edit by hand.
  onServersChanged: {
    if (root.editingId !== "" && !Model.findServer(root.servers, root.editingId)) root.cancelForm()
    if (root.expandedId !== "" && !Model.findServer(root.servers, root.expandedId)) root.expandedId = ""
    root.selectedIndex = Math.max(0, Math.min(root.servers.length - 1, root.selectedIndex))
  }

  // ----------------------------------------------------------------- cursor

  function hasCursorAt(index) { return root.cursorActive && root.selectedIndex === index }
  function takeCursor(index) { root.cursorActive = true; root.selectedIndex = index }

  function moveCursor(delta) {
    if (root.servers.length === 0) return
    var at = root.cursorActive ? root.selectedIndex : (delta > 0 ? -1 : 0)
    var next = ((at + delta) % root.servers.length + root.servers.length) % root.servers.length
    root.takeCursor(next)
  }

  function selectedServer() {
    if (!root.cursorActive) return null
    return root.servers[root.selectedIndex] || null
  }

  function activateCursor() {
    var server = root.selectedServer()
    if (server) root.toggleExpanded(server.id)
  }

  function removeSelected() {
    var server = root.selectedServer()
    if (server) root.removeServer(server.id)
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  // Visuals come from `hasCursor` only, never from containsMouse, so mouse
  // and keyboard can never light up two rows at once.
  component PanelRow: CursorSurface {
    id: rowSurface

    required property int rowIndex
    property bool activeRow: false

    readonly property bool selected: root.hasCursorAt(rowIndex)

    signal activated()

    width: parent ? parent.width : 0
    hasCursor: selected
    current: activeRow
    foreground: root.foreground
    accent: Color.accent

    onSelectedChanged: if (selected) scrollArea.ensureVisible(rowSurface)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.takeCursor(rowSurface.rowIndex)
      onClicked: rowSurface.activated()
    }
  }

  component StateBanner: BorderSurface {
    id: banner

    property color tone: root.foreground
    property string glyph: ""
    property string title: ""
    property string detail: ""

    width: parent ? parent.width : 0
    implicitHeight: bannerRow.implicitHeight + Style.spacing.xxl
    radius: Style.cornerRadius
    color: Style.hoverFillFor(banner.tone, banner.tone)
    borderSpec: Border.controlSpec("selected", banner.tone, banner.tone)

    Row {
      id: bannerRow
      anchors.centerIn: parent
      width: parent.width - Style.spacing.huge * 2
      spacing: Style.spacing.controlGap

      Text {
        textFormat: Text.PlainText
        text: banner.glyph
        color: banner.tone
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - Style.space(28)
        spacing: Style.spacing.xxs
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: banner.title
          color: banner.tone
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          width: parent.width
          text: banner.detail
          color: banner.tone
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // Every field shares one label column, so the inputs line up down the form
  // instead of stepping with the width of their labels.
  component FormRow: Item {
    id: formRow

    property string label: ""
    default property alias content: formHolder.children

    width: parent ? parent.width : 0
    implicitHeight: Math.max(labelText.implicitHeight, formHolder.childrenRect.height)

    Text {
      textFormat: Text.PlainText
      id: labelText
      text: formRow.label
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      width: root.labelColumn
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Item {
      id: formHolder
      anchors.left: labelText.right
      anchors.leftMargin: Style.spacing.controlGap
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: childrenRect.height
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Stands down whenever a text field owns the keyboard.
      blocked: nameField.activeFocus || hostField.activeFocus || portField.activeFocus
        || userField.activeFocus || identityField.activeFocus
        || timeoutField.activeFocus
      onMoveRequested: function(dx, dy) { root.moveCursor(dx !== 0 ? dx : dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.removeSelected()
      // One step at a time: abandoning an edit must not also close the panel.
      onCloseRequested: {
        if (root.editingId !== "") { root.cancelForm(); return }
        if (root.advancedOpen) { root.advancedOpen = false; return }
        root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "a" || text === "A") { nameField.forceActiveFocus(); return }
        if (text === "r" || text === "R") { root.refresh(); return }
        if (text === "p" || text === "P") { root.togglePaused(); return }
        var server = root.selectedServer()
        if (!server) return
        if (text === "c" || text === "C") root.connectTo(server.id)
        // Not "k": PanelKeyCatcher claims that one for moving up, and it
        // never reaches here.
        else if (text === "s" || text === "S") root.setupKey(server.id)
        else if (text === "e" || text === "E") root.startEdit(server)
      }

      Flickable {
        id: scrollArea
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        function ensureVisible(item) {
          if (!item || contentHeight <= height) return
          var top = item.mapToItem(contentColumn, 0, 0).y
          var margin = Style.spacing.lg
          if (top - margin < contentY) contentY = Math.max(0, top - margin)
          else if (top + item.height + margin > contentY + height)
            contentY = Math.min(contentHeight - height, top + item.height + margin - height)
        }

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: scrollArea.width
          spacing: Style.spacing.panelGap

          PanelHero {
            title: "Remote servers"
            meta: root.configError !== ""
              ? "servers.json cannot be read"
              : Model.summary(root.servers, root.stats, root.paused, root.networkOffline)
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.paused ? Model.GLYPH.pause
                  : (root.networkOffline ? Model.GLYPH.offline
                    : (root.alarmed ? Model.GLYPH.serverOff : Model.GLYPH.server))
                color: root.alarmed ? Color.urgent : (root.stale ? root.dim : root.foreground)
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.xs

                PanelActionButton {
                  iconText: root.paused ? Model.GLYPH.play : Model.GLYPH.pause
                  tooltipText: root.paused ? "Start checking again" : "Stop checking"
                  foreground: root.foreground
                  hoverColor: Color.accent
                  fontFamily: root.fontFamily
                  onClicked: root.togglePaused()
                }

                PanelActionButton {
                  iconText: Model.GLYPH.refresh
                  tooltipText: "Refresh now"
                  enabled: !root.paused && root.servers.length > 0
                  foreground: root.foreground
                  hoverColor: Color.accent
                  fontFamily: root.fontFamily
                  onClicked: root.refresh()
                }
              }
            }
          }

          StateBanner {
            visible: root.configError !== ""
            tone: Color.urgent
            glyph: Model.GLYPH.alert
            title: "servers.json"
            detail: root.configError
          }

          StateBanner {
            visible: root.paused
            tone: root.foreground
            glyph: Model.GLYPH.pause
            title: "Checks stopped"
            detail: "Nothing is being checked, press play above to start again"
          }

          // Unmissable on purpose: while the machine is offline, every line
          // below is the last thing that was known, not the current state.
          StateBanner {
            visible: !root.paused && root.networkOffline
            tone: Color.urgent
            glyph: Model.GLYPH.offline
            title: "No connection"
            detail: root.networkDetail === ""
              ? "Checks are paused until it comes back"
              : "Checks are paused, " + root.networkDetail
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: Model.errorText(root.actionError)
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          // -------------------------------------------------------------- form

          PanelSectionHeader {
            text: root.editingId === "" ? "ADD A SERVER" : "EDIT SERVER"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.spacing.md

            FormRow {
              label: "Name"
              TextField {
                id: nameField
                width: parent.width
                placeholderText: "What you'll call it here"
                text: root.draftName
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onTextChanged: root.draftName = text
                onAccepted: root.submitForm()
                Keys.onEscapePressed: root.editingId === "" ? keyCatcher.forceActiveFocus() : root.cancelForm()
              }
            }

            FormRow {
              label: "Host"
              TextField {
                id: hostField
                width: parent.width
                placeholderText: "example.com, or a ~/.ssh/config alias"
                text: root.draftHost
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onTextChanged: root.draftHost = text
                onAccepted: root.submitForm()
                Keys.onEscapePressed: root.editingId === "" ? keyCatcher.forceActiveFocus() : root.cancelForm()
              }
            }

            // Labelled, not a bare icon with a tooltip. A tooltip on a small
            // button at the panel's left edge is drawn in its own window,
            // flipped outward, landing outside the panel entirely.
            Button {
              text: root.advancedOpen ? "Fewer options" : "More options"
              iconText: root.advancedOpen ? "󰅀" : "󰅂"
              // Tabbable, or a port and a user could only be typed by someone
              // willing to reach for the mouse first.
              focusable: true
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.advancedOpen = !root.advancedOpen
            }

            Column {
              width: parent.width
              spacing: Style.spacing.md
              visible: root.advancedOpen

              FormRow {
                label: "Port"
                TextField {
                  id: portField
                  width: Style.space(90)
                  placeholderText: "22"
                  text: root.draftPort
                  foreground: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  onTextChanged: root.draftPort = text
                  onAccepted: root.submitForm()
                  Keys.onEscapePressed: root.editingId === "" ? keyCatcher.forceActiveFocus() : root.cancelForm()
                }
              }

              FormRow {
                label: "User"
                TextField {
                  id: userField
                  width: parent.width
                  placeholderText: "ssh's own default"
                  text: root.draftUser
                  foreground: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  onTextChanged: root.draftUser = text
                  onAccepted: root.submitForm()
                  Keys.onEscapePressed: root.editingId === "" ? keyCatcher.forceActiveFocus() : root.cancelForm()
                }
              }

              FormRow {
                label: "Identity file"
                TextField {
                  id: identityField
                  width: parent.width
                  placeholderText: "ssh-agent, or ~/.ssh/config"
                  text: root.draftIdentityFile
                  foreground: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  onTextChanged: root.draftIdentityFile = text
                  onAccepted: root.submitForm()
                  Keys.onEscapePressed: root.editingId === "" ? keyCatcher.forceActiveFocus() : root.cancelForm()
                }
              }

              FormRow {
                label: "Timeout"
                Row {
                  spacing: Style.spacing.controlGap

                  TextField {
                    id: timeoutField
                    width: Style.space(90)
                    placeholderText: String(Model.DEFAULT_TIMEOUT)
                    text: root.draftTimeoutSec
                    foreground: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    onTextChanged: root.draftTimeoutSec = text
                    onAccepted: root.submitForm()
                    Keys.onEscapePressed: root.editingId === "" ? keyCatcher.forceActiveFocus() : root.cancelForm()
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "seconds"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.formError
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Right-aligned on the same edge every input above ends on.
            Item {
              width: parent.width
              implicitHeight: submitButton.implicitHeight

              Button {
                id: cancelButton
                visible: root.editingId !== ""
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                height: submitButton.height
                anchors.right: submitButton.left
                anchors.rightMargin: Style.spacing.xs
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.cancelForm()
              }

              Button {
                id: submitButton
                text: root.editingId === "" ? "Add server" : "Save changes"
                iconText: root.editingId === "" ? Model.GLYPH.add : Model.GLYPH.edit
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.submitForm()
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "SERVERS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            visible: root.servers.length === 0
            text: "No servers yet. Add one above."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

            Repeater {
              model: root.servers

              delegate: Column {
                id: rowEntry
                required property var modelData
                required property int index

                readonly property bool expanded: root.expandedId === modelData.id
                readonly property bool editing: root.editingId === modelData.id
                readonly property var stat: root.stats[modelData.id]

                width: parent.width
                spacing: Style.spacing.sm

                onExpandedChanged: if (expanded) Qt.callLater(function() { scrollArea.ensureVisible(rowEntry) })

                PanelRow {
                  id: serverRow
                  rowIndex: rowEntry.index
                  activeRow: rowEntry.expanded || rowEntry.editing
                  implicitHeight: rowContent.implicitHeight + Style.spacing.xl
                  onActivated: root.toggleExpanded(rowEntry.modelData.id)

                  Item {
                    id: rowContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Style.spacing.rowPaddingX
                    anchors.rightMargin: Style.spacing.rowPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    implicitHeight: labels.implicitHeight

                    Text {
                      textFormat: Text.PlainText
                      id: dot
                      text: rowEntry.expanded ? "󰅀" : "●"
                      color: root.colorForRow(rowEntry.modelData)
                      font.family: root.fontFamily
                      font.pixelSize: rowEntry.expanded ? Style.font.caption : Style.font.bodySmall
                      anchors.left: parent.left
                      anchors.top: labels.top
                      anchors.topMargin: Math.max(0, Math.round((titleText.implicitHeight - implicitHeight) / 2))
                      width: root.dotColumn
                    }

                    Column {
                      id: labels
                      anchors.left: dot.right
                      anchors.right: actions.left
                      anchors.rightMargin: Style.spacing.lg
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.xxs

                      Text {
                        textFormat: Text.PlainText
                        id: titleText
                        width: parent.width
                        text: rowEntry.modelData.name
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        // Names what fixing it gets you, not just what is
                        // wrong: the fix is one row down, behind a click
                        // nobody would otherwise have a reason to try.
                        text: root.paused ? Model.PAUSED_TEXT
                          : (root.networkOffline ? Model.OFFLINE_TEXT
                            : (root.needsKey(rowEntry.stat)
                              ? "Set up a key to see load and RAM. Open this row."
                              : (rowEntry.stat
                                ? Model.rowStatLine(rowEntry.stat)
                                : ("not checked yet · " + Model.targetLabel(rowEntry.modelData)))))
                        color: !root.stale && Model.needsAttention(rowEntry.stat) ? Color.urgent : root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    Row {
                      id: actions
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.xs

                      PanelActionButton {
                        iconText: Model.GLYPH.console
                        tooltipText: "Open a console"
                        foreground: root.foreground
                        hoverColor: Color.accent
                        fontFamily: root.fontFamily
                        onClicked: root.connectTo(rowEntry.modelData.id)
                      }
                    }
                  }
                }

                // ------------------------------------------------ details
                Column {
                  visible: rowEntry.expanded
                  width: parent.width - root.detailIndent - Style.spacing.rowPaddingX
                  x: root.detailIndent
                  spacing: Style.spacing.sm

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: "ssh " + Model.targetLabel(rowEntry.modelData)
                      + (rowEntry.modelData.identityFile ? "  -i " + rowEntry.modelData.identityFile : "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: rowEntry.modelData.connectTimeoutSec + "s connect timeout"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  // Said once, where the button is, because "why does this
                  // need a key at all" is the question the button raises.
                  Text {
                    textFormat: Text.PlainText
                    visible: !root.stale && root.keyUnconfirmed(rowEntry.stat)
                    width: parent.width
                    text: "Load and RAM are sampled in the background, where a "
                      + "password prompt has nowhere to appear, so reading them "
                      + "needs a key. Set one up once and this row starts showing them."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Row {
                    width: parent.width
                    spacing: Style.spacing.xs

                    // Bordered and first whenever it is the thing that would
                    // fix this row: a server with no key-based auth reports
                    // it here and nowhere else.
                    Button {
                      text: "Set up key"
                      iconText: Model.GLYPH.key
                      bordered: !root.stale && root.keyUnconfirmed(rowEntry.stat)
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      onClicked: root.setupKey(rowEntry.modelData.id)
                    }

                    Button {
                      text: "Edit"
                      iconText: Model.GLYPH.edit
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      onClicked: root.startEdit(rowEntry.modelData)
                    }

                    Button {
                      text: "Remove"
                      iconText: Model.GLYPH.remove
                      foreground: root.foreground
                      accent: Color.urgent
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      onClicked: root.removeServer(rowEntry.modelData.id)
                    }
                  }
                }
              }
            }
          }

          // Separator and key/label pairs joined by U+00A0, so the line wraps
          // between hints and never inside one.
          Text {
            textFormat: Text.PlainText
            text: root.servers.length === 0
              ? "a add · Esc close"
              : "Enter details · c console · s set up key · e edit · Del remove · a add · r refresh · p pause · Esc close"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
