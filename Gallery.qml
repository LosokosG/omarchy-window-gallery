import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import QtQuick
import qs.Commons
import qs.Ui
import "WindowList.js" as WindowList

// Searchable gallery of live window previews. Hyprland IPC supplies ordering
// and geometry; the Wayland toplevel behind each entry is what screencopy
// captures. See docs/design.md for why previews cost nothing to capture.
Item {
  id: root

  // Injected by omarchy-shell's plugin loader.
  property var shell: null
  property var manifest: null

  // The shell reads `opened` to keep its own open/closed bookkeeping honest.
  property bool opened: false

  // Kept mapped briefly after close so the exit animation can play.
  property bool mounted: false
  // While committing we hand keyboard focus back to the compositor so the
  // window we are switching to can actually take it.
  property bool committing: false

  property string filterText: ""
  property int selectedIndex: 0
  property var allRows: []
  property var filtered: []

  // ---------------------------------------------------------------- theme
  //
  // Every value resolves from the shell's own tokens, so the gallery inherits
  // the active Omarchy theme and re-themes live.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int contentSpacing: Style.spacing.md
  readonly property int headerHeight: Math.max(Style.space(30), Style.font.heading + Style.spacing.controlPaddingY * 2)

  // ---------------------------------------------------------------- layout
  //
  // The card is sized from its content, so two windows get a small card and
  // twelve get a large one. BorderSurface insets (border + padding) are
  // counted explicitly: leaving them out makes the grid narrower than
  // columns * tileWidth, which silently wraps the last tile onto a row the
  // card is too short to show.
  readonly property real cardInsetX: Border.left(borderSpec) + Border.right(borderSpec) + contentMargin * 2
  readonly property real cardInsetY: Border.top(borderSpec) + Border.bottom(borderSpec) + contentMargin * 2

  readonly property int screenWidth: targetScreen ? targetScreen.width : 1920
  readonly property int screenHeight: targetScreen ? targetScreen.height : 1080

  // Previews have to be big enough to recognise at a glance, which means
  // scaling with the display rather than pinning one pixel size.
  readonly property int tileWidth: Math.round(
    Math.max(Style.space(210), Math.min(Style.space(330), screenWidth / 8)))
  readonly property int previewHeight: Math.round(tileWidth * 9 / 16)
  readonly property int labelHeight: Style.space(38)
  readonly property int tileHeight: previewHeight + labelHeight
  readonly property int maxColumns: 5

  readonly property int maxCardWidth: Math.round(Math.min(Style.space(1500), screenWidth * 0.72))
  readonly property int maxCardHeight: Math.round(Math.min(Style.space(900), screenHeight * 0.72))

  readonly property int columns: {
    var fits = Math.floor((maxCardWidth - cardInsetX) / tileWidth)
    var n = Math.max(1, filtered.length)
    return Math.max(1, Math.min(n, maxColumns, Math.max(1, fits)))
  }
  readonly property int gridRows: Math.max(1, Math.ceil(Math.max(1, filtered.length) / columns))

  // The screen the gallery should appear on: whichever monitor has focus.
  readonly property var targetScreen: {
    var monitor = Hyprland.focusedMonitor
    if (!monitor) return null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === monitor.name) return screens[i]
    return null
  }

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    root.filterText = ""
    root.committing = false
    root.rebuild()
    root.selectedIndex = 0
    root.mounted = true
    root.opened = true
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    unmountTimer.restart()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "losokos.window-gallery")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // Single entry point for the keybind: opens when closed, advances when
  // already open. One IPC call means no race between "is it open?" and
  // "act on it".
  function step(direction) {
    var delta = String(direction) === "prev" ? -1 : 1
    if (!root.opened) {
      root.open("{}")
      if (delta < 0) root.select(-1)
      return "opened"
    }
    root.select(delta)
    return "stepped"
  }

  // For a release-on-ALT binding, if one is wired up.
  function commit() {
    if (!root.opened) return "closed"
    root.activateIndex(root.selectedIndex)
    return "committed"
  }

  // ----------------------------------------------------------------- model

  function rebuild() {
    var players = Mpris.players ? Mpris.players.values : []
    root.allRows = WindowList.buildRows(Hyprland.toplevels ? Hyprland.toplevels.values : [], players)
    root.applyFilter()
  }

  function applyFilter() {
    root.filtered = WindowList.filterRows(root.allRows, root.filterText)
    if (root.filtered.length === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= root.filtered.length) root.selectedIndex = root.filtered.length - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
    root.applyFilter()
  }

  function select(delta) {
    var n = root.filtered.length
    if (n === 0) return
    root.selectedIndex = (root.selectedIndex + delta + n) % n
  }

  function selectRow(delta) {
    var n = root.filtered.length
    if (n === 0) return
    var next = root.selectedIndex + delta * root.columns
    if (next < 0 || next >= n) return
    root.selectedIndex = next
  }

  // ------------------------------------------------------------ activation

  function activateIndex(index) {
    var row = root.filtered[index]
    if (!row) return

    // Release the keyboard grab first, or the compositor has nowhere to hand
    // focus to.
    root.committing = true

    if (row.wayland && typeof row.wayland.activate === "function") row.wayland.activate()
    else if (row.address) Hyprland.dispatch('hl.dsp.focus({ window = "address:' + row.address + '" })')

    root.startFlight(row, index)
    root.opened = false
    unmountTimer.restart()
  }

  // The chosen tile animates onto the window's real position and dissolves
  // into it. Geometry comes from Hyprland, so this is a transform on a
  // texture already in hand. Windows that are not on screen right now have no
  // such rectangle, so they get a scale-and-fade instead.
  function startFlight(row, index) {
    var monitor = Hyprland.focusedMonitor
    var activeWs = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
    var onScreenNow = row.workspaceId === activeWs && row.at && row.size

    var item = grid.itemAtIndex(index)
    if (!item) return

    var origin = item.mapToItem(panelContent, 0, 0)
    flight.row = row
    flight.x = origin.x
    flight.y = origin.y
    flight.width = item.width
    flight.height = root.previewHeight
    flight.opacity = 1
    flight.visible = true

    if (onScreenNow && root.targetScreen) {
      flight.toX = row.at[0] - root.targetScreen.x
      flight.toY = row.at[1] - root.targetScreen.y
      flight.toWidth = row.size[0]
      flight.toHeight = row.size[1]
    } else {
      flight.toX = flight.x - flight.width * 0.06
      flight.toY = flight.y - flight.height * 0.06
      flight.toWidth = flight.width * 1.12
      flight.toHeight = flight.height * 1.12
    }

    flightAnimation.restart()
  }

  Timer {
    id: unmountTimer
    interval: 300
    onTriggered: {
      if (root.opened) return
      root.mounted = false
      root.committing = false
      flight.visible = false
      flight.row = null
    }
  }

  // Windows opening or closing while the gallery is up should be reflected,
  // but nothing here polls: this fires on Hyprland's own toplevel signal.
  Connections {
    target: Hyprland.toplevels
    ignoreUnknownSignals: true
    function onValuesChanged() { if (root.opened) root.rebuild() }
  }

  // -------------------------------------------------------------- surface

  PanelWindow {
    id: panel

    screen: root.targetScreen
    visible: root.mounted
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "losokos-window-gallery"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.committing ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive

    Item {
      id: panelContent
      anchors.fill: parent

      Rectangle {
        anchors.fill: parent
        color: root.scrim
        opacity: root.opened ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      }

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }

      BorderSurface {
        id: card

        width: Math.min(root.maxCardWidth, root.cardInsetX + root.columns * root.tileWidth)
        height: Math.min(root.maxCardHeight,
          root.cardInsetY + root.headerHeight + root.contentSpacing + root.gridRows * root.tileHeight)
        anchors.centerIn: parent
        radius: root.cornerRadius
        color: root.background
        borderSpec: root.borderSpec
        padding: root.contentMargin

        opacity: root.opened ? 1 : 0
        scale: root.opened ? 1 : 0.98
        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        // Clicks inside the card must not fall through to the dismiss handler.
        MouseArea { anchors.fill: parent; onClicked: {} }

        Item {
          id: keyCatcher
          anchors.fill: parent
          focus: true

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
              if (root.filterText) root.setFilter("")
              else root.dismiss()
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.activateIndex(root.selectedIndex)
              event.accepted = true
            } else if (event.key === Qt.Key_Tab) {
              root.select(event.modifiers & Qt.ShiftModifier ? -1 : 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Backtab) {
              root.select(-1)
              event.accepted = true
            } else if (event.key === Qt.Key_Left) {
              root.select(-1)
              event.accepted = true
            } else if (event.key === Qt.Key_Right) {
              root.select(1)
              event.accepted = true
            } else if (event.key === Qt.Key_Up) {
              root.selectRow(-1)
              event.accepted = true
            } else if (event.key === Qt.Key_Down) {
              root.selectRow(1)
              event.accepted = true
            } else if (Util.editsFilter(event, root.filterText)) {
              root.setFilter(Util.editedFilter(event, root.filterText))
              event.accepted = true
            } else if (event.text && event.text.length === 1
              && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
              root.setFilter(root.filterText + event.text)
              event.accepted = true
            }
          }
        }

        Column {
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: root.contentSpacing

          Item {
            width: parent.width
            height: root.headerHeight

            Text {
              anchors.left: parent.left
              anchors.right: countLabel.left
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              text: root.filterText || "Search windows…"
              color: root.foreground
              opacity: root.filterText ? 1 : 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideRight
            }

            Text {
              id: countLabel
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.filtered.length
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Item {
            width: parent.width
            height: parent.height - root.headerHeight - root.contentSpacing

            GridView {
              id: grid
              anchors.fill: parent
              model: root.filtered
              clip: true
              cellWidth: root.tileWidth
              cellHeight: root.tileHeight
              boundsBehavior: Flickable.StopAtBounds
              currentIndex: root.selectedIndex
              highlightFollowsCurrentItem: true
              highlightMoveDuration: 140
              onCurrentIndexChanged: positionViewAtIndex(currentIndex, GridView.Contain)

              // A single highlight rectangle slides between cells instead of
              // every tile animating itself.
              highlight: Rectangle {
                radius: root.cornerRadius
                color: root.selectedBackground
                border.width: Math.max(1, Style.space(2))
                border.color: root.selectedText
              }

              delegate: Item {
                id: tile
                required property var modelData
                required property int index

                width: root.tileWidth
                height: root.tileHeight

                readonly property bool isSelected: index === root.selectedIndex

                scale: isSelected || hoverArea.containsMouse ? 1.03 : 1.0
                Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

                Item {
                  anchors.fill: parent
                  anchors.margins: Style.spacing.sm

                  Rectangle {
                    id: previewFrame
                    width: parent.width
                    height: root.previewHeight - Style.spacing.sm * 2
                    radius: root.cornerRadius
                    color: Qt.rgba(0, 0, 0, 0.22)
                    clip: true

                    ScreencopyView {
                      id: preview
                      anchors.fill: parent
                      // Bound to `mounted`, so every capture is released when
                      // the gallery closes and nothing is held while idle.
                      captureSource: root.mounted ? tile.modelData.wayland : null
                      live: false
                      paintCursor: false
                      opacity: hasContent ? 1 : 0
                      Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                    }

                    // Shown until the frame lands, so a tile is never blank.
                    Text {
                      anchors.centerIn: parent
                      visible: !preview.hasContent
                      text: tile.modelData.glyph
                      color: root.foreground
                      opacity: 0.35
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.displayLarge
                    }

                    Row {
                      anchors.top: parent.top
                      anchors.right: parent.right
                      anchors.margins: Style.spacing.sm
                      spacing: Style.spacing.xs

                      Text {
                        visible: tile.modelData.fullscreen
                        text: ""
                        color: root.selectedText
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.iconSmall
                      }

                      Text {
                        visible: tile.modelData.playing
                        text: ""
                        color: root.selectedText
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.iconSmall
                      }
                    }
                  }

                  Row {
                    anchors.top: previewFrame.bottom
                    anchors.topMargin: Style.spacing.sm
                    width: parent.width
                    spacing: Style.spacing.sm

                    Text {
                      text: tile.modelData.glyph
                      color: root.foreground
                      opacity: 0.75
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Column {
                      width: parent.width - Style.font.body - Style.spacing.sm
                      spacing: 0

                      Text {
                        width: parent.width
                        text: tile.modelData.title
                        color: tile.isSelected ? root.selectedText : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        text: tile.modelData.playing && tile.modelData.trackTitle
                          ? tile.modelData.trackTitle
                          : (tile.modelData.workspaceName ? "Workspace " + tile.modelData.workspaceName : "")
                        color: root.foreground
                        opacity: 0.45
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }
                  }
                }

                MouseArea {
                  id: hoverArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) root.selectedIndex = tile.index
                  onClicked: {
                    root.selectedIndex = tile.index
                    root.activateIndex(tile.index)
                  }
                }
              }
            }

            Column {
              anchors.centerIn: parent
              spacing: Style.spacing.lg
              visible: root.filtered.length === 0

              Text {
                text: ""
                color: root.selectedText
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
              }

              Text {
                text: root.filterText ? "No windows match “" + root.filterText + "”" : "No other windows"
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
              }
            }
          }
        }
      }

      // The commit animation: the chosen preview, flying home.
      Item {
        id: flight
        visible: false
        z: 10

        property var row: null
        property real toX: 0
        property real toY: 0
        property real toWidth: 0
        property real toHeight: 0

        ScreencopyView {
          anchors.fill: parent
          captureSource: flight.row ? flight.row.wayland : null
          live: false
          paintCursor: false
        }

        ParallelAnimation {
          id: flightAnimation
          NumberAnimation { target: flight; property: "x"; to: flight.toX; duration: 210; easing.type: Easing.InOutCubic }
          NumberAnimation { target: flight; property: "y"; to: flight.toY; duration: 210; easing.type: Easing.InOutCubic }
          NumberAnimation { target: flight; property: "width"; to: flight.toWidth; duration: 210; easing.type: Easing.InOutCubic }
          NumberAnimation { target: flight; property: "height"; to: flight.toHeight; duration: 210; easing.type: Easing.InOutCubic }
          NumberAnimation { target: flight; property: "opacity"; to: 0; duration: 210; easing.type: Easing.InCubic }
        }
      }
    }
  }
}
