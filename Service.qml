import QtQuick
import Quickshell
import Quickshell.Io

// Shell plugins run inside the Quickshell process and cannot register a
// Hyprland keybind, so the binding has to be written into the user's
// bindings.lua. All of that logic lives in bin/omarchy-window-gallery-keybind
// rather than here, so the automatic install and the documented manual
// removal are the same code -- and so removal can take back exactly what the
// install added.
//
// This runs once: the script no-ops when its marker is already present, which
// also means a user who rebinds the gallery to a different key keeps it.
Item {
  id: root

  // Injected by omarchy-shell's plugin loader.
  property var shell: null
  property var manifest: null

  property bool keybindAttempted: false

  // The loader assigns `manifest` after createObject() returns, so
  // Component.onCompleted is too early to see it.
  onManifestChanged: root.installKeybind()

  function installKeybind() {
    if (root.keybindAttempted) return

    // Read __sourceDir straight off the manifest rather than through a bound
    // property: QML does not guarantee that a binding depending on `manifest`
    // has re-evaluated by the time this handler runs on the same signal.
    var dir = String((root.manifest && root.manifest.__sourceDir) || "")
    if (dir.indexOf("file://") === 0) dir = dir.substring(7)
    if (dir === "") return

    root.keybindAttempted = true
    keybindProcess.command = ["bash", dir + "/bin/omarchy-window-gallery-keybind", "install"]
    keybindProcess.running = true
  }

  Process {
    id: keybindProcess
    stderr: SplitParser {
      onRead: data => console.warn("losokos.window-gallery: " + data)
    }
  }
}
