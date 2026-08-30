# omarchy-window-gallery

A searchable **gallery of live window previews** for
[Omarchy](https://omarchy.org/) / Hyprland, bound to `ALT + TAB`.

Instead of cycling one window at a time, or reading a list of titles, you see
what is actually inside each window. Type to narrow, Enter to switch.

## Why

Omarchy binds `ALT + TAB` to "focus next window", which walks windows one at a
time — fine with three, tedious with a dozen. Text-based switchers help, but
five terminals all called `foot` still look identical in a list. Showing each
window's contents turns the decision from reading into recognising.

## Requirements

- Omarchy on the Quickshell-based `omarchy-shell` (tested on 4.0.0.alpha)
- Hyprland 0.56+ (tested on 0.56.2)
- Quickshell 0.3.1+ — needs `ScreencopyView`

## Install

```bash
omarchy plugin add https://github.com/LosokosG/omarchy-window-gallery.git --enable
```

The plugin's service installs the `ALT + TAB` binding into
`~/.config/hypr/bindings.lua` on first load and reloads Hyprland, so there is
no separate setup step. It writes once, keyed off its own marker, so
re-enabling or updating never duplicates the line — and if you change the key
afterwards, the plugin leaves your choice alone.

## Usage

| Key | Action |
|---|---|
| `ALT + TAB` | open the gallery / advance the selection |
| `ALT + SHIFT + TAB` | open / step backwards |
| `←` `→` `↑` `↓` | move the selection |
| type anything | filter by window title or app |
| `playing` / `fullscreen` | filter to media players or fullscreen windows |
| `Backspace` / `Ctrl+U` | edit / clear the filter |
| `Enter` or click | switch to the selected window |
| `Esc` | clear the filter, or cancel without switching |

Windows are ordered most-recently-used, so the first tile is always the window
you were just in — `ALT + TAB`, `Enter` is "go back". The current window is
left out, since switching to it does nothing.

Media players and fullscreen windows are grouped under their own headings,
above the main list; everything else stays in one most-recently-used group.
Headings only appear when there is more than one group, so the common case
stays a plain grid. Tiles are also badged — fullscreen and playing — and a
playing tile shows its track title in place of the workspace label.

Whatever the grouping, the selection starts on your most recently used window,
so "open, Enter" is always "go back".

## How it works

Hyprland's IPC supplies ordering (`focusHistoryID`), workspace, and geometry;
each entry's Wayland toplevel is what Quickshell's `ScreencopyView` captures.
`HyprlandToplevel.wayland` is the join between the two.

Previews are captured with `live: false` — one frame each, never a stream — and
every capture source is released when the gallery closes, so nothing is
retained while idle.

Windows on other workspaces preview correctly: Hyprland can produce a frame for
a toplevel that is not currently on screen.

### Performance

Measured on the development machine with 19 windows open:

| | |
|---|---|
| Memory cost of 19 captures | ~0 (12 KB over baseline — buffers are shared handles, not copies) |
| Time to paint all 19 previews | 23–57 ms, in parallel |
| Cost while closed | nothing: no timers, no polling, no retained captures |

An earlier design constrained capture sizes and culled off-screen tiles. Both
were removed after measurement showed there was no cost to optimise away. See
[`docs/design.md`](docs/design.md).

## Theming

Every colour, corner radius, font, and spacing value resolves from the shell's
own `Color.menu.*` and `Style.*` tokens, so the gallery matches the active
Omarchy theme and restyles live when you switch themes. There are no hardcoded
colours.

## Caveats

- Requires the Quickshell-based Omarchy shell — the plugin is an `overlay`
  kind and will not load on older wofi/walker-based releases.
- Removing the plugin does not remove the lines it added to `bindings.lua`;
  that file is outside the plugin directory. Delete the
  `-- Added by the losokos.window-gallery plugin.` block by hand.
- Browser tabs are not searchable. Firefox exposes no external API to activate
  a specific tab, which needs a browser extension and a native messaging host —
  a separate project. Each row already carries a `source` tag so tabs can be
  merged into the same list later.

## License

MIT
