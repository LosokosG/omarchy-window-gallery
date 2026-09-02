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

  // __sourceDir is stamped in by the plugin registry, and may arrive as a
  // plain path or a file:// URL.
  readonly property string pluginDir: {
    var dir = String((root.manifest && root.manifest.__sourceDir) || "")
    return dir.indexOf("file://") === 0 ? dir.substring(7) : dir
  }

  Component.onCompleted: {
    if (root.pluginDir === "") return
    keybindProcess.command = ["bash", root.pluginDir + "/bin/omarchy-window-gallery-keybind", "install"]
    keybindProcess.running = true
  }

  Process {
    id: keybindProcess
    stderr: SplitParser {
      onRead: data => console.warn("losokos.window-gallery: " + data)
    }
  }
}
