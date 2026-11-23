import QtQuick
import Quickshell.Io
import qs.Ui

// Omakvm in the bar: one icon that says whether keyboard, mouse and clipboard
// are being shared with the other machine, and the host for the panel that
// sets it up.
//
// Panel.qml owns the state and every process the plugin runs. This widget
// mirrors what the icon needs through guarded reads, because the bar creates
// it before the Loader has produced the panel.
BarWidget {
  id: root
  moduleName: "io.github.faeric.omakvm"

  // Two screens while sharing, one while not.
  readonly property string iconSharing: String.fromCodePoint(0xF037A)
  readonly property string iconIdle: String.fromCodePoint(0xF0379)

  readonly property bool sharing: panelLoader.item ? panelLoader.item.sharing === true : false
  readonly property string tier: panelLoader.item ? String(panelLoader.item.tier) : "unknown"
  readonly property string tooltipText: panelLoader.item ? String(panelLoader.item.tooltipText) : "Omakvm"

  // Only a fault takes the urgent colour. Sharing switched off is a state the
  // user chose, and the single-screen glyph already says so.
  readonly property bool attention: tier === "warn"

  // Shape the bar expects of a widget that owns a panel: open, close, opened.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function refresh() { if (panelLoader.item) panelLoader.item.refresh() }
  function toggleSharing() { if (panelLoader.item) panelLoader.item.toggleSharing() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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
    target: "io.github.faeric.omakvm"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.refresh() }
    function toggleSharing(): void { root.toggleSharing() }
    function status(): string { return root.tooltipText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.sharing ? root.iconSharing : root.iconIdle
    active: root.attention
    tooltipText: root.tooltipText

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleSharing()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
