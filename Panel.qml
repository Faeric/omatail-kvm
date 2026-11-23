import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Omakvm panel: choose the other machine and the screen edge it sits on,
// see what is working, and switch sharing on or off.
//
// Everything it knows comes from scripts/omakvm, which it runs as a child
// process and reads as JSON. Machine names come from Tailscale and from the
// other machine, so every piece of text that carries one is shown as plain
// text and passes through plain() first.
Panel {
  id: root
  moduleName: "io.github.faeric.omakvm"
  ipcTarget: "io.github.faeric.omakvm"
  // BarWidget.qml owns the single IpcHandler this target allows.
  manageIpc: false

  property var anchorItem: null

  // The bar identifies a panel by the widget mounted in its slot, which is
  // BarWidget.qml, not this nested panel.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property int refreshIntervalSec: {
    var value = Number(setting("refreshIntervalSec", 30))
    return isFinite(value) ? Math.max(5, Math.min(3600, Math.round(value))) : 30
  }

  // Resolved from this file's own location, so the scripts are found wherever
  // the plugin is checked out.
  readonly property string pluginDir: {
    var text = String(Qt.resolvedUrl("."))
    if (text.indexOf("file://") !== 0) return ""
    try { text = decodeURIComponent(text.slice(7)) } catch (e) { return "" }
    return text.replace(/\/+$/, "")
  }
  readonly property string cli: pluginDir + "/scripts/omakvm"

  // ---- State, as scripts/omakvm reports it --------------------------------

  property bool loaded: false
  property bool installed: false
  property string peerAddress: ""
  property string peerName: ""
  property string peerPosition: ""
  property string firewall: "unknown"
  property bool reachable: false
  property bool paired: false
  property bool kvmActive: false
  property bool clipActive: false
  property bool clipPaused: false

  // Machines offered as the peer: [{ name, address, online }].
  property var candidates: []

  // What is picked in the panel but not applied yet.
  property string pendingAddress: ""
  property string pendingPosition: ""

  // Once a machine is chosen the list folds down to it, so the state rows
  // stay in view; `choosing` unfolds it again.
  property bool choosing: false
  readonly property var listedCandidates: {
    if (choosing || !configured) return candidates
    var current = []
    for (var i = 0; i < candidates.length; i++)
      if (candidates[i].address === peerAddress) current.push(candidates[i])
    return current.length > 0 ? current : [{ name: peerName, address: peerAddress, online: reachable }]
  }

  property string busyAction: ""
  property string failure: ""

  readonly property bool busy: busyAction !== ""
  readonly property bool configured: peerAddress !== ""
  readonly property bool installOk: installed && (firewall === "open" || firewall === "none")
  readonly property bool needsSetup: configured && (!installed || firewall === "closed")
  readonly property bool sharing: configured && kvmActive

  readonly property string selectedAddress: pendingAddress !== "" ? pendingAddress : peerAddress
  readonly property string selectedPosition: pendingPosition !== "" ? pendingPosition : peerPosition
  readonly property bool dirty: selectedAddress !== "" && selectedPosition !== ""
    && (selectedAddress !== peerAddress || selectedPosition !== peerPosition)

  // ok: sharing and everything answers. warn: something needs attention.
  // idle: nothing chosen, or switched off. unknown: not checked yet.
  readonly property string tier: {
    if (!loaded) return "unknown"
    if (!configured) return "idle"
    if (needsSetup) return "warn"
    if (!sharing) return "idle"
    if (!reachable || !paired) return "warn"
    return "ok"
  }

  readonly property string statusLine: {
    if (!loaded) return strings.t("status.checking")
    if (!configured) return strings.t("status.unconfigured")
    if (needsSetup) return strings.t("status.needsSetup")
    if (!sharing) return strings.t("status.off").arg(peerName)
    if (!reachable) return strings.t("status.unreachable").arg(peerName)
    if (!paired) return strings.t("status.unpaired").arg(peerName)
    return strings.t("status.sharing." + peerPosition).arg(peerName)
  }
  readonly property string tooltipText: strings.t("tooltip").arg(statusLine)

  // ---- Look ---------------------------------------------------------------

  // Guarded so the panel renders before the bar is injected.
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(contentForeground, 1.4)
  readonly property color okColor: Style.selectedStateColor(contentForeground, Color.accent)

  // Nerd Font (Material Design) glyphs.
  readonly property string iconScreens: String.fromCodePoint(0xF037A)
  readonly property string iconScreen: String.fromCodePoint(0xF0379)
  readonly property string iconInstall: String.fromCodePoint(0xF01DA)
  readonly property string iconLink: String.fromCodePoint(0xF0339)
  readonly property string iconPairing: String.fromCodePoint(0xF0498)
  readonly property string iconKeyboard: String.fromCodePoint(0xF030C)
  readonly property string iconClipboard: String.fromCodePoint(0xF0192)
  readonly property string iconRefresh: String.fromCodePoint(0xF0450)
  readonly property string iconPause: String.fromCodePoint(0xF03E4)
  readonly property string iconPlay: String.fromCodePoint(0xF040A)
  readonly property string iconOk: String.fromCodePoint(0xF012C)
  readonly property string iconWarn: String.fromCodePoint(0xF0026)
  readonly property string iconUnknown: String.fromCodePoint(0xF02D7)

  function verdictIcon(verdict) {
    if (verdict === "ok") return iconOk
    if (verdict === "warn") return iconWarn
    return iconUnknown
  }

  function verdictColor(verdict) {
    if (verdict === "ok") return okColor
    if (verdict === "warn") return urgent
    return dim
  }

  // Names arrive from outside. Whatever is not a plain host-name character is
  // dropped, and the result is clipped, before it is shown anywhere.
  function plain(value) {
    return String(value === undefined || value === null ? "" : value)
      .replace(/[^A-Za-z0-9._ -]/g, "").slice(0, 63)
  }

  function validAddress(value) {
    return /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$/.test(String(value))
  }

  function validPosition(value) {
    return value === "left" || value === "right" || value === "top" || value === "bottom"
  }

  // ---- Lifecycle ----------------------------------------------------------

  function open() {
    refresh()
    loadCandidates()
    root.controller.show()
    // After showing: showing hands the popout coordinator over, which closes
    // whichever panel was open, and that close clears the shared flag.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.pendingAddress = ""
    root.pendingPosition = ""
    root.choosing = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still holding
  // must not keep the center indicators revealed behind the panel. Newer
  // shells expose a setter and make the property read-only.
  function setCenterHoverRevealSuppressed(value) {
    if (!root.bar) return
    if (typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
  }

  // ---- Reading state ------------------------------------------------------

  function refresh() {
    if (pluginDir === "" || statusProc.running) return
    statusProc.command = [cli, "status", "--json"]
    statusProc.running = true
  }

  function applyStatus(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { return }
    if (!data || typeof data !== "object") return

    var peer = data.peer && typeof data.peer === "object" ? data.peer : null
    var address = peer && validAddress(peer.address) ? String(peer.address) : ""
    var clipboard = data.clipboard && typeof data.clipboard === "object" ? data.clipboard : {}

    root.installed = data.installed === true
    root.peerAddress = address
    root.peerName = address !== "" ? (plain(peer.name) || address) : ""
    root.peerPosition = address !== "" && validPosition(peer.position) ? peer.position : ""
    root.firewall = ["open", "closed", "none"].indexOf(data.firewall) >= 0 ? data.firewall : "unknown"
    root.reachable = data.reachable === true
    root.paired = data.paired === true
    root.kvmActive = data.kvm === "active"
    root.clipActive = clipboard.incoming === "active" && clipboard.outgoing === "active"
    root.clipPaused = clipboard.paused === true
    root.loaded = true
  }

  function loadCandidates() {
    if (pluginDir === "" || candidatesProc.running) return
    candidatesProc.command = [cli, "candidates"]
    candidatesProc.running = true
  }

  function applyCandidates(text) {
    var list
    try { list = JSON.parse(text) } catch (e) { return }
    if (!Array.isArray(list)) return

    var result = []
    for (var i = 0; i < list.length && result.length < 24; i++) {
      var entry = list[i]
      if (!entry || !validAddress(entry.address)) continue
      // A machine that is offline is offered only when it is the current peer:
      // Tailscale keeps retired entries around under the same name.
      if (entry.online !== true && entry.address !== root.peerAddress) continue
      result.push({
        name: plain(entry.name) || String(entry.address),
        address: String(entry.address),
        online: entry.online === true
      })
    }
    root.candidates = result
  }

  // ---- Acting -------------------------------------------------------------

  function run(name, args) {
    if (pluginDir === "" || actionProc.running) return false
    root.failure = ""
    root.busyAction = name
    actionProc.command = [cli].concat(args)
    actionProc.running = true
    return true
  }

  function selectCandidate(address) {
    if (!validAddress(address)) return
    root.pendingAddress = address === root.peerAddress ? "" : address
    // A machine that already has this one on an edge decides the other edge.
    if (address !== root.peerAddress && !hintProc.running) {
      hintProc.command = [cli, "hint", address]
      hintProc.running = true
    }
  }

  function selectPosition(position) {
    if (!validPosition(position)) return
    root.pendingPosition = position === root.peerPosition ? "" : position
  }

  function apply() {
    if (!dirty || !validAddress(selectedAddress) || !validPosition(selectedPosition)) return
    run("configure", ["configure", selectedAddress, selectedPosition])
  }

  function toggleSharing() {
    if (!configured) { open(); return }
    run(sharing ? "disable" : "enable", [sharing ? "disable" : "enable"])
  }

  function togglePause() {
    run(clipPaused ? "resume" : "pause", [clipPaused ? "resume" : "pause"])
  }

  function pairNow() {
    run("pair", ["pair"])
  }

  // The privileged step runs in a terminal of its own, where the password
  // prompt is visible. It finishes the configuration when it is done.
  function runSetup() {
    if (pluginDir === "" || !configured) return
    Quickshell.execDetached([cli, "setup"])
    close()
  }

  function finishAction(name, exitCode, output) {
    root.busyAction = ""
    var appliedAddress = root.selectedAddress
    if (name === "configure" && (exitCode === 0 || exitCode === 4)) {
      root.pendingAddress = ""
      root.pendingPosition = ""
      root.choosing = false
    }
    if (exitCode === 4 && name === "configure") {
      // The choice is saved, lan-mouse is not installed: go and install it.
      root.peerAddress = appliedAddress
      runSetup()
    } else if (exitCode !== 0 && !(name === "pair" && exitCode === 3)) {
      var lines = String(output || "").trim().split("\n")
      root.failure = String(lines[lines.length - 1] || "").replace(/[^\x20-\x7E]/g, "").slice(0, 200)
    }
    refresh()
  }

  Process {
    id: statusProc
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyStatus(String(statusOut.text || ""))
    }
  }

  Process {
    id: candidatesProc
    running: false
    command: []
    stdout: StdioCollector { id: candidatesOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyCandidates(String(candidatesOut.text || ""))
    }
  }

  Process {
    id: hintProc
    running: false
    command: []
    stdout: StdioCollector { id: hintOut; waitForEnd: true }
    onExited: function(exitCode) {
      var position = String(hintOut.text || "").trim()
      if (exitCode === 0 && root.validPosition(position) && root.pendingAddress !== "")
        root.pendingPosition = position === root.peerPosition ? "" : position
    }
  }

  Process {
    id: actionProc
    running: false
    command: []
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.finishAction(root.busyAction, exitCode,
        String(actionErr.text || "") !== "" ? actionErr.text : actionOut.text)
    }
  }

  Timer {
    running: true
    repeat: true
    interval: 1000 * (root.opened ? 5 : root.refreshIntervalSec)
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()

  // ---- Rows ---------------------------------------------------------------

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.contentForeground
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.body
  }

  component StateRow: Item {
    id: row

    property string rowIcon: ""
    property string label: ""
    property string detail: ""
    property string verdict: "unknown"
    property string actionIcon: ""
    property string actionTooltip: ""
    property bool actionVisible: false

    signal actionTriggered()

    implicitHeight: Math.max(Style.space(38), rowText.implicitHeight + Style.space(12))

    PlainText {
      id: rowGlyph
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      text: row.rowIcon
      color: root.dim
      font.pixelSize: Style.font.icon
    }

    Column {
      id: rowText
      anchors.left: rowGlyph.right
      anchors.leftMargin: Style.space(10)
      anchors.right: rowVerdict.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      PlainText {
        width: parent.width
        text: row.label
        font.bold: true
        elide: Text.ElideRight
      }

      PlainText {
        width: parent.width
        visible: row.detail !== ""
        text: row.detail
        color: root.dim
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }

    // The verdict is carried by the glyph as well as the colour, so it still
    // reads on a theme whose accent and urgent colours are close.
    PlainText {
      id: rowVerdict
      anchors.right: rowAction.visible ? rowAction.left : parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: root.verdictIcon(row.verdict)
      color: root.verdictColor(row.verdict)
      font.pixelSize: Style.font.icon
    }

    PanelActionButton {
      id: rowAction
      anchors.right: parent.right
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      visible: row.actionVisible && row.actionIcon !== ""
      enabled: !root.busy
      iconText: row.actionIcon
      tooltipText: row.actionTooltip
      foreground: root.contentForeground
      fontFamily: root.contentFontFamily
      onClicked: row.actionTriggered()
    }
  }

  component PositionButton: Button {
    property string position: ""

    width: positionGrid.cellWidth
    foreground: root.contentForeground
    fontFamily: root.contentFontFamily
    bordered: true
    enabled: !root.busy && root.selectedAddress !== ""
    opacity: enabled ? 1.0 : 0.45
    selected: root.selectedPosition === position
    text: strings.t("position." + position)
    onClicked: root.selectPosition(position)
  }

  // ---- Panel --------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (String(t).toLowerCase() === "r") { root.refresh(); root.loadCandidates() }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // What is happening, and the switch that changes it.
          PanelHero {
            id: hero
            width: parent.width
            title: strings.t("title")
            meta: root.statusLine
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            iconOpacity: root.sharing ? 1.0 : 0.5

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.sharing ? root.iconScreens : root.iconScreen
                color: root.tier === "warn" ? root.urgent
                  : (root.tier === "ok" ? root.okColor : root.dim)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              ToggleSwitch {
                id: sharingSwitch
                checked: root.sharing
                busy: root.busyAction === "enable" || root.busyAction === "disable"
                interactive: root.configured && !root.busy
                foreground: hero.foreground
                onToggled: root.toggleSharing()

                PanelToolTip {
                  visible: sharingSwitch.containsMouse
                  text: root.sharing ? strings.t("toggle.off") : strings.t("toggle.on")
                  fontFamily: hero.fontFamily
                }
              }
            }
          }

          // Why the last action failed, in the script's own words.
          PlainText {
            width: parent.width
            visible: root.failure !== ""
            text: root.failure
            color: root.urgent
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.contentForeground }

          // Which machine.
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: strings.t("section.machine")
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            Repeater {
              model: root.listedCandidates

              Button {
                required property var modelData

                width: parent.width
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                leftAlign: true
                bordered: true
                enabled: !root.busy
                opacity: modelData.online ? 1.0 : 0.55
                selected: modelData.address === root.selectedAddress
                iconText: selected ? root.iconOk : ""
                text: modelData.name + "   " + modelData.address
                onClicked: root.selectCandidate(modelData.address)
              }
            }

            Button {
              width: parent.width
              visible: root.configured && !root.choosing && root.candidates.length > 1
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              leftAlign: true
              enabled: !root.busy
              text: strings.t("machine.change")
              onClicked: root.choosing = true
            }

            PlainText {
              width: parent.width
              visible: !root.configured && root.candidates.length === 0
              text: strings.t("machine.none")
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // Which edge of this screen it sits on.
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: strings.t("section.position")
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            Grid {
              id: positionGrid
              width: parent.width
              columns: 4
              columnSpacing: Style.space(6)

              readonly property real cellWidth: Math.floor((width - columnSpacing * 3) / 4)

              PositionButton { position: "left" }
              PositionButton { position: "right" }
              PositionButton { position: "top" }
              PositionButton { position: "bottom" }
            }

            Button {
              width: parent.width
              visible: root.dirty || root.busyAction === "configure"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              bordered: true
              active: true
              enabled: root.dirty && !root.busy
              opacity: enabled ? 1.0 : 0.45
              iconText: root.iconOk
              iconSpinning: root.busyAction === "configure"
              text: strings.t("apply")
              tooltipText: strings.t("apply.tooltip")
              onClicked: root.apply()
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // What is working.
          Column {
            width: parent.width
            spacing: Style.space(2)

            PanelSectionHeader {
              text: strings.t("section.state")
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            PlainText {
              width: parent.width
              visible: !root.configured
              text: strings.t("row.none")
              color: root.dim
              font.pixelSize: Style.font.bodySmall
            }

            StateRow {
              width: parent.width
              visible: root.configured
              rowIcon: root.iconInstall
              label: strings.t("row.install")
              verdict: root.installOk ? "ok" : (root.needsSetup ? "warn" : "unknown")
              detail: !root.installed ? strings.t("row.install.missing")
                : (root.firewall === "closed" ? strings.t("row.install.firewall")
                  : (root.installOk ? strings.t("row.install.ok") : strings.t("row.install.unknown")))
              actionIcon: root.iconInstall
              actionTooltip: strings.t("row.install.action")
              actionVisible: !root.installOk
              onActionTriggered: root.runSetup()
            }

            StateRow {
              width: parent.width
              visible: root.configured
              rowIcon: root.iconLink
              label: strings.t("row.link")
              verdict: root.reachable ? "ok" : "warn"
              detail: (root.reachable ? strings.t("row.link.ok") : strings.t("row.link.bad")).arg(root.peerName)
            }

            StateRow {
              width: parent.width
              visible: root.configured
              rowIcon: root.iconPairing
              label: strings.t("row.pairing")
              verdict: root.paired ? "ok" : "warn"
              detail: root.paired ? strings.t("row.pairing.ok") : strings.t("row.pairing.bad")
              actionIcon: root.iconRefresh
              actionTooltip: strings.t("row.pairing.action")
              actionVisible: !root.paired && root.installed
              onActionTriggered: root.pairNow()
            }

            StateRow {
              width: parent.width
              visible: root.configured
              rowIcon: root.iconKeyboard
              label: strings.t("row.kvm")
              verdict: root.kvmActive ? "ok" : "unknown"
              detail: root.kvmActive ? strings.t("row.kvm.ok") : strings.t("row.kvm.bad")
            }

            StateRow {
              width: parent.width
              visible: root.configured
              rowIcon: root.iconClipboard
              label: strings.t("row.clipboard")
              verdict: root.clipActive && !root.clipPaused ? "ok" : "unknown"
              detail: !root.clipActive ? strings.t("row.clipboard.bad")
                : (root.clipPaused ? strings.t("row.clipboard.paused") : strings.t("row.clipboard.ok"))
              actionIcon: root.clipPaused ? root.iconPlay : root.iconPause
              actionTooltip: root.clipPaused ? strings.t("row.clipboard.resume") : strings.t("row.clipboard.pause")
              actionVisible: root.clipActive
              onActionTriggered: root.togglePause()
            }
          }
        }
      }
    }
  }
}
