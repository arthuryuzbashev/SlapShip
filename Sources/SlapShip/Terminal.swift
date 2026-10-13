import AppKit
import ApplicationServices

/// Optional "hands on the keyboard" actions: Esc to interrupt, `/compact` on a hard slap.
/// Only fires when a known terminal is frontmost, and needs Accessibility permission.
enum TerminalKeys {
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.github.wez.wezterm", "dev.zed.Zed",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    ]

    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func askPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static var terminalIsFrontmost: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return terminals.contains(id)
    }

    static func interrupt() {
        guard hasPermission, terminalIsFrontmost else { return }
        press(keyCode: 53) // Esc
    }

    static func compact() {
        guard hasPermission, terminalIsFrontmost else { return }
        type("/compact")
        press(keyCode: 36) // Return
    }

    private static func press(keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private static func type(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in text.utf16 {
            var c = ch
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            up?.post(tap: .cghidEventTap)
        }
    }
}
