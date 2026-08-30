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

// Build the row list, most-recently-used first. The currently focused window
// is dropped: switching to it is a no-op, and leaving it out makes the first
// tile reliably "the window I was just in".
function buildRows(toplevels, players) {
  var rows = []

  for (var i = 0; i < toplevels.length; i++) {
    var tl = toplevels[i]
    if (!tl) continue

    var ipc = tl.lastIpcObject || {}
    if (ipc.mapped === false) continue

    var mru = typeof ipc.focusHistoryID === "number" ? ipc.focusHistoryID : 9999
    if (mru === 0) continue

    var appClass = String(ipc.class || "")
    var media = matchPlayer(appClass, players)
    var ws = ipc.workspace || {}

    rows.push({
      source: "window",
      address: String(tl.address || ""),
      title: String(ipc.title || tl.title || "(untitled)"),
      appClass: appClass,
      glyph: glyphFor(appClass),
      workspaceId: typeof ws.id === "number" ? ws.id : -1,
      workspaceName: String(ws.name || ""),
      monitorName: String(ipc.monitor !== undefined ? ipc.monitor : ""),
      fullscreen: !!ipc.fullscreen,
      floating: !!ipc.floating,
      at: ipc.at || null,
      size: ipc.size || null,
      playing: media ? media.playing : false,
      trackTitle: media ? media.track : "",
      wayland: tl.wayland,
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
