import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Tabby bar widget: tab count in the bar, and a panel with quick actions,
// profiles, theme/font sync status and the integration settings.
// All state comes from `omarchy-tabby status --json`; every action goes
// through the same CLI, so the widget holds no logic of its own.
Panel {
  id: root
  moduleName: "io.github.saurasanchezpablo.tabby"
  ipcTarget: "io.github.saurasanchezpablo.tabby"
  manageIpc: false

  // ---------- Settings (shell.json entry) ----------
  readonly property bool showTabs: setting("showTabs", true) !== false
  readonly property bool hideWhenClosed: setting("hideWhenClosed", false) === true
  readonly property int pollSeconds: Model.clampInterval(setting("pollInterval", 4), 4)

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------- State ----------
  // Hot reload destroys this object while processes may still report back.
  property bool alive: true
  property var status: ({})
  property var schema: []
  property bool loaded: false
  property string lastJson: ""

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string cli: pluginDir + "/bin/omarchy-tabby"
  readonly property bool running: Model.running(status)
  readonly property bool setupNeeded: Model.setupNeeded(status)
  property bool settingUp: false
  readonly property bool problem: Model.problem(status)
  readonly property var profiles: Model.visibleProfiles(status)
  readonly property var toggles: Model.toggleSettings(schema)
  readonly property var tuiSetting: Model.enumSetting(schema, "tuiTerminal")
  readonly property var settingsValues: status && status.settings ? status.settings : ({})

  Component.onDestruction: alive = false

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function run(args) {
    Quickshell.execDetached(["bash", root.cli].concat(args))
    refreshSoon.restart()
  }

  function newTab() { run(["open"]) }
  function newWindow() { run(["open", "--window"]) }
  function toggleDropdown() { run(["scratchpad"]) }
  function focusTabby() { run(["focus"]) }
  function openProfile(id) { run(["open", "--profile", String(id)]); close() }
  function applyTheme() { run(["apply"]) }
  function toggleSetting(key) { run(["settings", "toggle", String(key)]) }
  function setSetting(key, value) { run(["settings", "set", String(key), String(value)]) }
  function toggleDefault() { run(["default", "toggle"]) }
  // The bundled installer: the command, the Tabby plugin, Hyprland rules and
  // menu entries. Clicking the button is the consent; the default terminal
  // is left alone (it stays a separate toggle).
  function setUp() {
    settingUp = true
    Quickshell.execDetached(["bash", root.pluginDir + "/install.sh", "--yes", "--no-widget"])
    setupDone.restart()
  }

  onOpenedChanged: if (opened) refresh()

  visible: !(hideWhenClosed && loaded && !running)
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  Process {
    id: statusProc
    command: ["bash", root.cli, "status", "--json", "--fast"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.alive) return
        var json = String(text || "").trim()
        if (json === "" || json === root.lastJson) return
        root.lastJson = json
        root.status = Model.parseStatus(json)
        root.loaded = true
      }
    }
  }

  Process {
    id: schemaProc
    command: ["bash", root.cli, "settings", "list", "--json"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.alive) return
        try {
          var list = JSON.parse(String(text || "[]"))
          if (Array.isArray(list)) root.schema = list
        } catch (e) {}
      }
    }
  }

  Timer {
    interval: (root.opened ? 2 : root.pollSeconds) * 1000
    running: root.alive
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: setupDone
    interval: 4000
    onTriggered: if (root.alive) { root.settingUp = false; root.refresh() }
  }

  Timer {
    id: refreshSoon
    interval: 600
    onTriggered: if (root.alive) root.refresh()
  }

  IpcHandler {
    target: "io.github.saurasanchezpablo.tabby"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function status(): string { return root.lastJson }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: button.vertical ? Model.ICONS.terminal : Model.barText(root.status, root.showTabs)
    active: root.problem
    dimmed: root.loaded && !root.running
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.newTab()
      else if (b === Qt.RightButton) root.toggleDropdown()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "n") root.newTab()
        else if (t === "w") root.newWindow()
        else if (t === "d") root.toggleDropdown()
        else if (t === "f") root.focusTabby()
        else if (t === "a") root.applyTheme()
        else if (t === "r") root.refresh()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.problem ? Model.ICONS.warning : Model.ICONS.terminal
            color: root.problem ? root.urgentColor : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "Tabby"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: Model.statusLine(root.status).toUpperCase()
              color: root.problem ? root.urgentColor : Qt.darker(root.fg, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---------- Setup (marketplace installs get only this widget) ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.setupNeeded

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: "Installs the omarchy-tabby command and Tabby's companion plugin (Omarchy theme, font and clipboard in Tabby; your current ones are backed up), adds a Hyprland rule with free keybindings and Setup > Tabby to the menu. Undo with: omarchy-tabby uninstall"
            color: root.fg
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            width: parent.width
            iconText: Model.ICONS.check
            text: root.settingUp ? "Setting up…" : "Set up the Tabby integration"
            enabled: !root.settingUp
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.setUp()
          }
        }

        // ---------- Actions ----------
        Row {
          id: actionRow
          width: parent.width
          spacing: Style.space(6)
          readonly property real cellWidth: (width - spacing * 3) / 4

          ActionButton { iconText: Model.ICONS.plus; text: "Tab"; tooltipText: "New tab (n)"; onClicked: root.newTab() }
          ActionButton { iconText: Model.ICONS.window; text: "Window"; tooltipText: "New window (w)"; onClicked: root.newWindow() }
          ActionButton { iconText: Model.ICONS.dropdown; text: "Dropdown"; tooltipText: "Toggle the dropdown (d)"; onClicked: root.toggleDropdown() }
          ActionButton { iconText: Model.ICONS.focus; text: root.running ? "Focus" : "Start"; tooltipText: "Focus Tabby (f)"; onClicked: root.focusTabby() }
        }

        // ---------- Profiles ----------
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.profiles.length > 0

          PanelSeparator { foreground: root.fg }

          PanelSectionHeader {
            text: "PROFILES"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.profiles
            Button {
              required property var modelData
              width: parent.width
              leftAlign: true
              iconText: Model.profileIcon(modelData.type)
              text: String(modelData.name)
              tooltipText: String(modelData.type)
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.openProfile(modelData.id)
            }
          }
        }

        // ---------- Omarchy sync ----------
        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSeparator { foreground: root.fg }

          PanelSectionHeader {
            text: "OMARCHY SYNC"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          InfoPair {
            label: Model.ICONS.palette + "  Colours"
            value: Model.syncLabel(root.status.colors, root.status.theme)
          }
          InfoPair {
            label: Model.ICONS.font + "  Font"
            value: Model.syncLabel(root.status.font, root.status.fontFamily)
          }

          Button {
            visible: root.status.colors === "paused" || root.status.font === "paused"
            width: parent.width
            iconText: Model.ICONS.refresh
            text: "Use the Omarchy theme again (a)"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.applyTheme()
          }
        }

        // ---------- Settings ----------
        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator { foreground: root.fg }

          PanelSectionHeader {
            text: "INTEGRATION"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Toggle {
            width: parent.width
            label: "Default terminal"
            description: "SUPER+RETURN and Omarchy launch Tabby"
            checked: root.status.default === true
            foreground: root.fg
            fontFamily: root.fontFamily
            titleSize: Style.font.bodySmall
            onClicked: root.toggleDefault()
          }

          Repeater {
            model: root.toggles
            Toggle {
              required property var modelData
              width: parent.width
              label: String(modelData.label)
              description: String(modelData.description)
              checked: root.settingsValues[modelData.key] === true
              foreground: root.fg
              fontFamily: root.fontFamily
              titleSize: Style.font.bodySmall
              onClicked: root.toggleSetting(modelData.key)
            }
          }

          Dropdown {
            visible: root.tuiSetting !== null
            width: parent.width
            label: root.tuiSetting ? String(root.tuiSetting.label) : ""
            value: String(root.settingsValues.tuiTerminal || "auto")
            options: root.tuiSetting ? root.tuiSetting.options : []
            fontFamily: root.fontFamily
            onChanged: function(v) { root.setSetting("tuiTerminal", v) }
          }
        }
      }
    }
  }

  component ActionButton: Button {
    width: actionRow.cellWidth
    iconSize: Style.font.title
    fontSize: Style.font.bodySmall
    foreground: root.fg
    fontFamily: root.fontFamily
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
    bordered: true
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      id: pairLabel
      textFormat: Text.PlainText
      text: parent.label
      color: root.fg
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      textFormat: Text.PlainText
      text: parent.value
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
      width: parent.width - pairLabel.implicitWidth - parent.spacing
    }
  }
}
