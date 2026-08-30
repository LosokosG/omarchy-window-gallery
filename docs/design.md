# Window Gallery — design

An Omarchy shell plugin that replaces Alt-Tab cycling with a searchable
gallery of **live window previews**.

## Problem

Omarchy's ALT+TAB (`hl.dsp.window.cycle_next`) walks windows one at a time.
That is fine at three windows and tedious at a dozen. The existing
`xadacka.window-switcher` improves on it with a searchable text list, but it
drives Omarchy's generic `omarchy.menu` overlay, whose row delegate renders
plain text only — so it can never show window contents. Finding "the right
terminal" among five identically-named terminals still means reading titles.

Showing each window's actual contents makes the choice visual instead of
textual.

## Verified constraints

Everything below was measured on this machine (Hyprland 0.56.2, Quickshell
0.3.1, Omarchy 4.0.0.alpha) before the design was fixed. These are
measurements, not assumptions.

| Question | Method | Result |
|---|---|---|
| Can a window on an inactive workspace be captured? | probe: window parked on ws 9, viewer on ws 1 | **Yes** — `hasContent` true, full size |
| Does `constraintSize` cap the captured buffer? | same capture with and without it | **No** — presentation-only; `sourceSize` identical (3416x1386 both) |
| What does a capture cost in memory? | 19 captures vs 0-capture baseline, same process | **~0** — 12 KB delta; buffers are shared handles, not pixel copies |
| How long until previews paint? | timed `hasContent` for 19 windows | **23–57 ms warm**, all in parallel; 124 ms cold-process |

The third and fourth rows killed the original plan. An earlier draft proposed
viewport culling, per-tile capture constraints, and a two-tier resolution
scheme. All three optimize a cost that does not exist. **The design is
simpler because the measurement said so.**

## Architecture

Two entry points in one plugin:

- `overlay` (`Gallery.qml`) — the UI. Loaded by `omarchy-shell`, `keepLoaded`
  so reopening is warm (23 ms, not 124 ms).
- `service` (`Service.qml`) — idempotently installs the ALT+TAB keybind into
  `~/.config/hypr/bindings.lua`, since shell plugins cannot register Hyprland
  binds directly.

### Data flow

```
Hyprland.toplevels ──┬─ address, title, workspace, monitor
                     ├─ lastIpcObject ─ focusHistoryID (MRU), class,
                     │                  fullscreen, at[], size[]
                     └─ wayland ──────→ ScreencopyView.captureSource
Mpris.players ───────────────────────→ now-playing badge + track title
```

`HyprlandToplevel.wayland` is the join that makes this work: Hyprland's IPC
supplies ordering and geometry, the Wayland toplevel supplies the capture
source. One list, two protocols.

### Item model

A plain JS array (not `ListModel`) because rows must carry the Wayland
toplevel **object** through to the delegate, which `ListModel` cannot hold.

Each row is source-tagged (`source: "window"`) so a future tab source can be
merged into the same list without restructuring anything. That tag is the
only concession to project 2; nothing else anticipates it.

## Interaction

ALT+TAB opens the gallery with the **previously focused** window already
selected, so ALT+TAB → Enter is "go back", and the current window is omitted
(switching to it is a no-op).

| Key | Action |
|---|---|
| ALT+TAB (again) | advance selection — routed through the `step` IPC method |
| ←/→, ↑/↓ | move selection |
| Tab / Shift+Tab | next / previous |
| any printable char | filter by title, app, or badge keyword |
| Backspace, Ctrl+U | edit / clear the filter |
| Enter, click | switch to the selected window |
| Esc | clear filter, or cancel with focus unchanged |

Filtering matches window title and app class, plus the keywords `playing` and
`fullscreen` which select on badges.

Ordering is strict MRU (`focusHistoryID` ascending), always. Fullscreen and
now-playing appear as tile badges rather than as separate groups, so the
first tile is reliably the last window.

## Motion

Timings are chosen to sit under the perceptual threshold for "instant" while
staying legible.

- **Open** — scrim fades in, card scales 0.98 → 1.0 over 140 ms, `OutCubic`.
  Individual previews fade in as their frames land, which is naturally
  staggered by capture completion (0–50 ms). No artificial stagger.
- **Selection** — one highlight rectangle animates between cells
  (`highlightMoveDuration: 140`). A single moving element rather than
  per-tile animation: cheaper, and calmer to look at.
- **Hover** — tile lifts to 1.03 scale. Identical treatment to keyboard
  selection so mouse and keyboard never disagree about what is selected.
- **Commit** — the chosen tile animates to the window's real on-screen
  rectangle and dissolves into it as the scrim clears. The geometry is
  already known (`lastIpcObject.at` / `.size`), so this is a transform on a
  texture already held. Windows not currently on screen (another workspace or
  monitor) have no such rectangle and get a scale-and-fade instead.

Every colour, radius, font, and spacing value resolves from `Color.menu.*`
and `Style.*`, so the plugin inherits the active Omarchy theme and re-themes
live with no restart.

## Performance

- `live: false` — each preview is one frame, never a stream. Zero CPU once
  painted.
- `captureSource` is bound to `opened`, so every capture is released on close
  and nothing is retained while idle. Release-then-re-arm was verified to
  work across three cycles in one process.
- The panel is `visible: false` when closed: no rendering, no timers.
- No polling anywhere. The window list is rebuilt on open and on toplevel
  changes, not on a clock.

## Non-goals

- **Browser tabs.** Separate project. Firefox exposes no external API to
  activate a specific tab; that needs a WebExtension plus a native-messaging
  host and its own install story. The `source` tag on each row is the only
  preparation made here.
- **Live-updating previews.** A gallery is open for a second or two. Streaming
  frames would spend CPU to animate something nobody is watching.
- **Replacing the Omarchy menu.** This is one overlay with one job.

## Testing

Manual, on the real compositor, because the whole feature is compositor
behaviour:

1. Previews render for windows on the current workspace.
2. Previews render for windows on other workspaces (the case that motivated
   the probe).
3. MRU order is correct: first tile is the previously focused window.
4. Enter switches focus, including across workspaces.
5. Esc leaves focus untouched.
6. Filtering narrows and keeps selection valid.
7. Badges appear for a fullscreen window and for a playing media player.
8. Theme switch restyles the overlay without a shell restart.
9. Memory returns to baseline after close.
