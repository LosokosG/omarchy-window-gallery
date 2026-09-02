import Quickshell
import Quickshell.Io
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
  property var tabRows: []
  property var filtered: []

  // Where the Firefox extension's native host publishes the tab list. Absent
  // when the extension is not installed, in which case the gallery simply
  // shows windows.
  readonly property string runtimeDir:
    (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-window-gallery"
  readonly property string tabsPath: runtimeDir + "/tabs.json"
  readonly property string thumbDir: runtimeDir + "/thumbs"

  // manifest.__sourceDir is stamped in by the plugin registry; it may arrive
  // as a plain path or a file:// URL.
  readonly property string pluginDir: {
    var dir = String((root.manifest && root.manifest.__sourceDir) || "")
    return dir.indexOf("file://") === 0 ? dir.substring(7) : dir
  }
  readonly property string tabHostScript: pluginDir + "/browser/native-host/omarchy-window-gallery-host.py"

  property int tabsShown: 0
  property int tabsTotal: 0

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

  readonly property int groupHeaderHeight: Style.font.bodySmall + Style.spacing.md
  readonly property int groupGap: Style.spacing.lg

  // Group spans for `filtered`, set alongside it in applyFilter().
  property var groups: []

  // Absolute placement for tiles and headers. The selection ring reads the
  // same arithmetic, so it cannot drift from the tiles it highlights.
  readonly property var layout: WindowList.layoutGroups(
    { rows: filtered, groups: groups }, columns, tileWidth, tileHeight,
    groupHeaderHeight, groupGap)

  readonly property var selectedTile: {
    var tiles = layout.tiles
    for (var i = 0; i < tiles.length; i++)
      if (tiles[i].index === selectedIndex) return tiles[i]
    return null
  }

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
    // The cached toplevel list drifts: it accumulates helper surfaces that
    // Hyprland never describes, so ask for an authoritative one on every open.
    root.rebuild()
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

  // Asks Hyprland for its client list; rebuildFrom() runs when it answers.
  function rebuild() {
    Hyprland.refreshToplevels()
    tabsProcess.running = true
    clientsProcess.running = true
  }

  // Missing file, no extension, malformed content: all mean "no tabs", never
  // an error the user has to care about.
  function loadTabs(tabsJson) {
    var tabs = []
    try {
      tabs = JSON.parse(tabsJson)
    } catch (e) {
      tabs = []
    }
    root.tabRows = Array.isArray(tabs)
      ? WindowList.buildTabRows(tabs, WindowList.glyphFor("firefox"))
      : []
  }

  function rebuildFrom(clientsJson) {
    var clients = []
    try {
      clients = JSON.parse(clientsJson)
    } catch (e) {
      console.warn("window-gallery: could not parse hyprctl clients output:", e)
      return
    }
    if (!Array.isArray(clients)) return

    // The Wayland toplevel is only needed for its capture handle, so the
    // cached list is fine here -- a missing entry costs a preview, not a row.
    var waylandByAddress = ({})
    var toplevels = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < toplevels.length; i++) {
      var tl = toplevels[i]
      if (tl && tl.wayland)
        waylandByAddress[WindowList.normalizeAddress(tl.address)] = tl.wayland
    }

    var players = Mpris.players ? Mpris.players.values : []
    root.allRows = WindowList.buildRows(clients, waylandByAddress, players)
    root.applyFilter()
    root.selectedIndex = WindowList.mostRecentIndex(root.filtered)
  }

  Process {
    id: tabsProcess
    command: ["cat", root.tabsPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadTabs(text)
    }
  }

  Process {
    id: clientsProcess
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.rebuildFrom(text)
    }
  }

  function applyFilter() {
    var combined = root.allRows.concat(root.tabRows)
    var matched = WindowList.filterRows(combined, root.filterText)

    // Unfiltered, show only the most recent handful of tabs; searching lifts
    // the cap, because that is when someone is hunting for one.
    var capped = root.filterText
      ? { rows: matched, shown: 0, total: 0 }
      : WindowList.capTabs(matched, 6)
    root.tabsShown = capped.shown
    root.tabsTotal = capped.total

    var grouped = WindowList.groupRows(capped.rows)
    for (var i = 0; i < grouped.groups.length; i++) {
      if (grouped.groups[i].title === "Tabs" && root.tabsTotal > root.tabsShown)
        grouped.groups[i].title = "Tabs (" + root.tabsShown + " of " + root.tabsTotal + ")"
    }
    root.filtered = grouped.rows
    root.groups = grouped.groups
    if (root.filtered.length === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= root.filtered.length) root.selectedIndex = root.filtered.length - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
    root.applyFilter()
  }

  // Keep the selection on screen when it moves past the visible rows.
  function ensureVisible() {
    var tile = root.selectedTile
    if (!tile || !flick) return
    if (tile.y < flick.contentY)
      flick.contentY = tile.y
    else if (tile.y + root.tileHeight > flick.contentY + flick.height)
      flick.contentY = tile.y + root.tileHeight - flick.height
  }

  onSelectedIndexChanged: Qt.callLater(root.ensureVisible)

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

    // Release the keyboard grab first: while the layer surface holds
    // exclusive focus the compositor has nowhere to hand focus to, and the
    // switch is silently dropped.
    root.committing = true

    root.startFlight(row, index)
    root.opened = false
    unmountTimer.restart()

    // Focus on the next tick, once the keyboardFocus change above has
    // actually reached the compositor.
    Qt.callLater(function () { root.focusRow(row) })
  }

  // Hyprland's dispatcher is authoritative and follows the window across
  // workspaces. It goes through hyprctl rather than Hyprland.dispatch(),
  // which does not take effect here even with an identical request string.
  // The Wayland activate() request is the portable fallback, but Hyprland
  // ignores it from a layer surface that was holding focus.
  function focusRow(row) {
    if (!row) return

    if (row.source === "tab") {
      root.focusTab(row)
      return
    }

    if (row.address)
      Quickshell.execDetached(["hyprctl", "dispatch",
        'hl.dsp.focus({ window = "address:' + row.address + '" })'])
    else if (row.wayland && typeof row.wayland.activate === "function")
      row.wayland.activate()
  }

  // Two halves: the extension selects the tab inside Firefox, and Hyprland
  // raises the browser window. Neither alone puts the tab in front of you.
  function focusTab(row) {
    Quickshell.execDetached(["python3", root.tabHostScript, "--activate",
      String(row.tabId), String(row.windowId)])

    var browser = null
    for (var i = 0; i < root.allRows.length; i++) {
      var candidate = root.allRows[i]
      if (candidate.appClass.toLowerCase().indexOf("firefox") >= 0
        && (browser === null || candidate.mru < browser.mru))
        browser = candidate
    }
    if (browser && browser.address)
      Quickshell.execDetached(["hyprctl", "dispatch",
        'hl.dsp.focus({ window = "address:' + browser.address + '" })'])
  }

  // The chosen tile animates onto the window's real position and dissolves
  // into it. Geometry comes from Hyprland, so this is a transform on a
  // texture already in hand. Windows that are not on screen right now have no
  // such rectangle, so they get a scale-and-fade instead.
  function startFlight(row, index) {
    var monitor = Hyprland.focusedMonitor
    var activeWs = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
    var onScreenNow = row.workspaceId === activeWs && row.at && row.size

    var tile = null
    for (var i = 0; i < root.layout.tiles.length; i++)
      if (root.layout.tiles[i].index === index) tile = root.layout.tiles[i]
    if (!tile) return

    var inset = Style.spacing.sm
    var origin = gridContent.mapToItem(panelContent, tile.x + inset, tile.y + inset)
    flight.row = row
    flight.x = origin.x
    flight.y = origin.y
    flight.width = root.tileWidth - inset * 2
    flight.height = root.previewHeight - inset * 2
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
          root.cardInsetY + root.headerHeight + root.contentSpacing + Math.max(root.tileHeight, root.layout.height))
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

            Flickable {
              id: flick
              anchors.fill: parent
              clip: true
              contentWidth: gridContent.width
              contentHeight: gridContent.height
              boundsBehavior: Flickable.StopAtBounds
              visible: root.filtered.length > 0

              Item {
                id: gridContent
                width: root.columns * root.tileWidth
                height: root.layout.height

                // One ring slides between tiles rather than every tile
                // animating itself: cheaper, and calmer to look at.
                Rectangle {
                  id: ring
                  visible: root.selectedTile !== null
                  x: (root.selectedTile ? root.selectedTile.x : 0) + Style.spacing.xs
                  y: (root.selectedTile ? root.selectedTile.y : 0) + Style.spacing.xs
                  width: root.tileWidth - Style.spacing.xs * 2
                  height: root.tileHeight - Style.spacing.xs * 2
                  radius: root.cornerRadius
                  color: root.selectedBackground
                  border.width: Math.max(1, Style.space(2))
                  border.color: root.selectedText

                  Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                  Behavior on y { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                }

                Repeater {
                  model: root.layout.headers

                  Text {
                    required property var modelData
                    x: Style.spacing.sm
                    y: modelData.y
                    height: root.groupHeaderHeight
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.title.toUpperCase()
                    color: root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }
                }

                Repeater {
                  model: root.layout.tiles

                  Item {
                    id: tile
                    required property var modelData

                    readonly property var row: root.filtered[modelData.index] || null
                    readonly property bool isSelected: modelData.index === root.selectedIndex

                    x: modelData.x
                    y: modelData.y
                    width: root.tileWidth
                    height: root.tileHeight
                    visible: row !== null

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

                        // Sized to cover the frame rather than fit inside
                        // it: a tiled window is usually taller than a 16:9
                        // tile, and fitting shrinks its preview to a narrow
                        // strip between two dead bars. Anchored to the top,
                        // where the content that identifies a window is.
                        ScreencopyView {
                          id: preview

                          readonly property real frameAspect:
                            previewFrame.height > 0 ? previewFrame.width / previewFrame.height : 1
                          readonly property real sourceAspect:
                            sourceSize.height > 0 ? sourceSize.width / sourceSize.height : frameAspect
                          readonly property bool wider: sourceAspect > frameAspect

                          anchors.horizontalCenter: parent.horizontalCenter
                          y: 0
                          width: wider ? previewFrame.height * sourceAspect : previewFrame.width
                          height: wider ? previewFrame.height : previewFrame.width / sourceAspect
                          // Bound to `mounted`, so captures are released on
                          // close and nothing is held while idle.
                          captureSource: root.mounted && tile.row ? tile.row.wayland : null
                          live: false
                          paintCursor: false
                          opacity: hasContent ? 1 : 0
                          Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                        }

                        // Tabs cannot be captured live, so they show the
                        // thumbnail taken when they were last on screen.
                        // sourceSize caps decode resolution: the file is
                        // ~500px wide but only a tile's worth is ever decoded.
                        Image {
                          id: tabThumb
                          anchors.fill: parent
                          visible: tile.row !== null && tile.row.source === "tab"
                          source: root.mounted && tile.row && tile.row.source === "tab"
                            ? "file://" + root.thumbDir + "/" + tile.row.tabId + ".jpg"
                            : ""
                          fillMode: Image.PreserveAspectCrop
                          asynchronous: true
                          cache: false
                          sourceSize.width: root.tileWidth
                          opacity: status === Image.Ready ? 1 : 0
                          Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                        }

                        // Shown until something lands, so a tile is never blank.
                        Text {
                          anchors.centerIn: parent
                          visible: !preview.hasContent && tabThumb.status !== Image.Ready
                          text: tile.row ? tile.row.glyph : ""
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
                            visible: tile.row ? tile.row.fullscreen : false
                            text: "\uf065"
                            color: root.selectedText
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.iconSmall
                          }

                          Text {
                            visible: tile.row ? tile.row.playing : false
                            text: "\uf04b"
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
                          text: tile.row ? tile.row.glyph : ""
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
                            text: tile.row ? tile.row.title : ""
                            color: tile.isSelected ? root.selectedText : root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            elide: Text.ElideRight
                          }

                          Text {
                            width: parent.width
                            text: !tile.row ? ""
                              : tile.row.source === "tab"
                                ? (tile.row.host || "browser tab")
                                : (tile.row.playing && tile.row.trackTitle
                                  ? tile.row.trackTitle
                                  : (tile.row.workspaceName ? "Workspace " + tile.row.workspaceName : ""))
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
                      onContainsMouseChanged: if (containsMouse) root.selectedIndex = tile.modelData.index
                      onClicked: {
                        root.selectedIndex = tile.modelData.index
                        root.activateIndex(tile.modelData.index)
                      }
                    }
                  }
                }
              }
            }

            Column {
              anchors.centerIn: parent
              spacing: Style.spacing.lg
              visible: root.filtered.length === 0

              Text {
                text: "\uf002"
                color: root.selectedText
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
              }

              Text {
                text: root.filterText ? "No windows match \u201c" + root.filterText + "\u201d" : "No other windows"
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
