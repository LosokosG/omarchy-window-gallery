import QtQuick
import Quickshell
import Quickshell.Io

// Shell plugins run inside the Quickshell process and cannot register a
// Hyprland keybind directly, so this idempotently appends one to
// ~/.config/hypr/bindings.lua the first time the plugin loads, then never
// touches it again. Safe on every shell start: it is a no-op once the marker
// is present, which also means the user is free to change the key afterwards
// without this putting the default back.
Item {
  id: root

  // Injected by omarchy-shell's plugin loader.
  property var shell: null
  property var manifest: null

  readonly property string moduleName: "losokos.window-gallery"
  readonly property string home: Quickshell.env("HOME")
  readonly property string bindingsFile: home + "/.config/hypr/bindings.lua"

  // Omarchy stacks TWO defaults on ALT + TAB (window.cycle_next and
  // window.bring_to_top) and two more on ALT + SHIFT + TAB, so each key is
  // unbound twice before being rebound.
  readonly property string bootstrapScript:
    'set -euo pipefail\n'
    + 'bindings="' + bindingsFile + '"\n'
    + '[[ -e "$bindings" ]] || exit 0\n'
    + 'grep -qF "' + moduleName + '" "$bindings" && exit 0\n'
    // Build the new file alongside the target and rename(2) it into place.
    // The bindings path is never opened for writing, so nothing swapped into
    // it mid-run can redirect a write, and rename replaces the directory
    // entry itself rather than following a symlink at that path.
    + 'dir=$(dirname -- "$bindings")\n'
    + 'tmp=$(mktemp "$dir/.bindings.lua.XXXXXX")\n'
    + 'trap \'rm -f "$tmp"\' EXIT\n'
    + 'cp -- "$bindings" "$tmp"\n'
    + '{\n'
    + '  echo ""\n'
    + '  echo "-- Added by the ' + moduleName + ' plugin."\n'
    + '  echo "pcall(hl.unbind, \\"ALT + TAB\\")"\n'
    + '  echo "pcall(hl.unbind, \\"ALT + TAB\\")"\n'
    + '  echo "pcall(hl.unbind, \\"ALT + SHIFT + TAB\\")"\n'
    + '  echo "pcall(hl.unbind, \\"ALT + SHIFT + TAB\\")"\n'
    + '  echo "o.bind(\\"ALT + TAB\\", \\"Window gallery\\", \\"omarchy-shell shell call ' + moduleName + ' step next\\")"\n'
    + '  echo "o.bind(\\"ALT + SHIFT + TAB\\", \\"Window gallery (back)\\", \\"omarchy-shell shell call ' + moduleName + ' step prev\\")"\n'
    + '} >> "$tmp"\n'
    + 'chmod --reference="$bindings" "$tmp" 2>/dev/null || true\n'
    + 'mv -f -- "$tmp" "$bindings"\n'
    + 'trap - EXIT\n'
    + 'command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true\n'

  Component.onCompleted: bootstrapProcess.running = true

  Process {
    id: bootstrapProcess
    command: ["bash", "-c", root.bootstrapScript]
    stderr: SplitParser {
      onRead: data => console.warn(root.moduleName + ": " + data)
    }
  }
}
