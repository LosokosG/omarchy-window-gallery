.pragma library

// Pure model logic for the gallery: turn Hyprland toplevels (plus MPRIS
// players) into an ordered, filterable row list. Kept free of QML singletons
// so it stays reasonable to reason about on its own.

// Nerd Font glyphs (FontAwesome block, which the shell's menu font carries in
// full) keyed off window class. Order matters: the first match wins, so
// narrower patterns are listed before broader ones.
var GLYPHS = [
  [/obsidian/,                                            ""],  // book
  [/ghostty|alacritty|kitty|foot|wezterm|xterm|konsole|terminal/, ""],  // terminal
  [/firefox|librewolf|floorp|zen-browser|waterfox/,       ""],  // firefox
  [/chromium|chrome|vivaldi|brave|edge|opera/,            ""],  // chrome
  [/code|cursor|sublime|jetbrains|idea|pycharm|webstorm|zed|vim|emacs/, ""],  // code
  [/steam/,                                               ""],  // steam
  [/spotify/,                                             ""],  // music
  [/vlc|mpv|celluloid|resolve|davinci/,                   ""],  // film
  [/^obs$|obsproject|obs-studio/,                         ""],  // video camera
  [/curseforge|minecraft|prismlauncher|lutris|heroic/,    ""],  // gamepad
  [/gimp|inkscape|krita/,                                 ""],  // image
  [/thunderbird/,                                         ""],  // envelope
  [/discord|vesktop|slack|telegram|signal|beeper/,        ""],  // comments
  [/nautilus|thunar|pcmanfm|dolphin|nemo|files/,          ""]   // folder
]

var FALLBACK_GLYPH = ""  // desktop

function glyphFor(appClass) {
  var c = String(appClass || "").toLowerCase()
  for (var i = 0; i < GLYPHS.length; i++)
    if (GLYPHS[i][0].test(c)) return GLYPHS[i][1]
  return FALLBACK_GLYPH
}

// An MPRIS player and a window are the same app when either identifier
// contains the other -- "spotify" matches class "Spotify", and desktopEntry
// "firefox" matches class "firefox". Whitespace is stripped so "Mozilla
// Firefox" can match too.
function matchPlayer(appClass, players) {
  var c = String(appClass || "").toLowerCase()
  if (!c || !players) return null

  for (var i = 0; i < players.length; i++) {
    var p = players[i]
    if (!p) continue
    var keys = [p.desktopEntry, p.identity]
    for (var k = 0; k < keys.length; k++) {
      var key = String(keys[k] || "").toLowerCase().replace(/\s+/g, "")
      if (!key) continue
      if (c.indexOf(key) >= 0 || key.indexOf(c) >= 0) {
        // Quickshell exposes isPlaying; fall back to the raw state string in
        // case a player only reports one of the two.
        var playing = p.isPlaying === true || String(p.playbackState || "") === "Playing"
        return { playing: playing, track: String(p.trackTitle || "") }
      }
    }
  }
  return null
}

// Quickshell reports a toplevel address without the "0x" prefix, while
// Hyprland's `address:` selector requires it. Dispatching the bare form is
// silently a no-op, so normalize here rather than at each call site.
function normalizeAddress(address) {
  var a = String(address || "")
  if (!a) return ""
  return a.indexOf("0x") === 0 ? a : "0x" + a
}

// A toplevel Hyprland does not describe is not a switchable window. Wine,
// Proton, and Electron apps create helper surfaces ("Default IME", "Input",
// hidden launcher shells) that appear in the Wayland toplevel list but have
// no Hyprland client behind them, so lastIpcObject never arrives. Requiring a
// described workspace and a non-zero size drops them without needing a
// blocklist of app-specific titles.
function isRealWindow(ipc) {
  if (!ipc) return false
  if (ipc.mapped === false) return false
  if (ipc.hidden === true) return false
  if (!ipc.workspace || typeof ipc.workspace.id !== "number") return false
  if (!ipc.size || ipc.size[0] < 32 || ipc.size[1] < 32) return false
  return true
}

// Build the row list, most-recently-used first, from Hyprland's own client
// list. `clients` is the parsed output of `hyprctl clients -j`;
// `waylandByAddress` maps a normalized address to the Wayland toplevel that
// screencopy captures.
//
// Hyprland's client list is read fresh rather than taken from Quickshell's
// cached toplevels: the cache both lags on focus order and carries helper
// surfaces Hyprland never describes.
//
// The currently focused window is dropped: switching to it is a no-op, and
// leaving it out makes "open, Enter" mean "the window I was just in".
function buildRows(clients, waylandByAddress, players) {
  var rows = []

  for (var i = 0; i < clients.length; i++) {
    var c = clients[i]
    if (!isRealWindow(c)) continue

    var mru = typeof c.focusHistoryID === "number" ? c.focusHistoryID : 9999
    if (mru === 0) continue

    var appClass = String(c.class || "")
    var media = matchPlayer(appClass, players)
    var ws = c.workspace || {}
    var address = normalizeAddress(c.address)

    rows.push({
      source: "window",
      address: address,
      title: String(c.title || "(untitled)"),
      appClass: appClass,
      glyph: glyphFor(appClass),
      workspaceId: typeof ws.id === "number" ? ws.id : -1,
      workspaceName: String(ws.name || ""),
      monitorName: String(c.monitor !== undefined ? c.monitor : ""),
      fullscreen: !!c.fullscreen,
      floating: !!c.floating,
      at: c.at || null,
      size: c.size || null,
      playing: media ? media.playing : false,
      trackTitle: media ? media.track : "",
      wayland: waylandByAddress[address] || null,
      mru: mru
    })
  }

  rows.sort(function (a, b) { return a.mru - b.mru })
  return rows
}

// Space-separated terms are ANDed. "playing" and "fullscreen" select on
// badges rather than text, so they can be combined with a normal search:
// "playing fire" finds a playing Firefox.
function filterRows(rows, text) {
  var query = String(text || "").trim().toLowerCase()
  if (!query) return rows

  var terms = query.split(/\s+/)
  var out = []

  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    var haystack = (r.title + " " + r.appClass + " " + r.trackTitle
      + " " + r.workspaceName).toLowerCase()
    var keep = true

    for (var t = 0; t < terms.length; t++) {
      var term = terms[t]
      if (term === "playing") { if (!r.playing) { keep = false; break } continue }
      if (term === "fullscreen") { if (!r.fullscreen) { keep = false; break } continue }
      if (haystack.indexOf(term) < 0) { keep = false; break }
    }

    if (keep) out.push(r)
  }

  return out
}

// ---------------------------------------------------------------- grouping
//
// Media players and fullscreen windows get their own groups so they can be
// picked out at a glance; everything else stays in one most-recently-used
// list. Order within every group remains MRU, and a window belongs to exactly
// one group so nothing is shown twice.
var GROUP_ORDER = [
  { key: "playing", title: "Playing" },
  { key: "fullscreen", title: "Fullscreen" },
  { key: "windows", title: "Windows" }
]

function groupKeyFor(row) {
  if (row.playing) return "playing"
  if (row.fullscreen) return "fullscreen"
  return "windows"
}

// Returns rows reordered by group, plus the group spans over that order.
// Reordering here (rather than in the view) keeps selectedIndex a plain index
// into one flat array, so keyboard movement never has to know about groups.
function groupRows(rows) {
  var buckets = {}
  for (var g = 0; g < GROUP_ORDER.length; g++) buckets[GROUP_ORDER[g].key] = []
  for (var i = 0; i < rows.length; i++) buckets[groupKeyFor(rows[i])].push(rows[i])

  var ordered = []
  var groups = []
  for (var k = 0; k < GROUP_ORDER.length; k++) {
    var bucket = buckets[GROUP_ORDER[k].key]
    if (bucket.length === 0) continue
    groups.push({ title: GROUP_ORDER[k].title, offset: ordered.length, count: bucket.length })
    for (var b = 0; b < bucket.length; b++) ordered.push(bucket[b])
  }

  return { rows: ordered, groups: groups }
}

// Index of the most-recently-used row, wherever grouping put it. Selecting
// this on open keeps "open, Enter" meaning "the window I was just in" even
// when that window sits inside a group rather than first overall.
function mostRecentIndex(rows) {
  var best = -1
  var bestMru = Infinity
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].mru < bestMru) { bestMru = rows[i].mru; best = i }
  }
  return best < 0 ? 0 : best
}

// Absolute placement for every tile and header. Computing positions here,
// rather than letting a layout do it, means the selection ring can be placed
// by the same arithmetic and can never disagree with the tiles.
function layoutGroups(grouped, columns, tileWidth, tileHeight, headerHeight, groupGap) {
  var showHeaders = grouped.groups.length > 1
  var tiles = []
  var headers = []
  var y = 0

  for (var g = 0; g < grouped.groups.length; g++) {
    var group = grouped.groups[g]
    if (g > 0) y += groupGap
    if (showHeaders) {
      headers.push({ title: group.title, y: y })
      y += headerHeight
    }
    for (var i = 0; i < group.count; i++) {
      tiles.push({
        index: group.offset + i,
        x: (i % columns) * tileWidth,
        y: y + Math.floor(i / columns) * tileHeight
      })
    }
    y += Math.ceil(group.count / columns) * tileHeight
  }

  return { tiles: tiles, headers: headers, height: y }
}
