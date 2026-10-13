import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let sound = WhipSound()
    private var hotkey: Hotkey?
    private var sensor: SlapSensor?
    private var sensorSeen = false
    private var slapWatcher: DispatchSourceFileSystemObject?
    private var slapOffset: UInt64 = 0
    private let defaults = UserDefaults.standard
    /// Our own crack shakes the chassis enough to look like a slap, so the sensor is deaf while it plays.
    private var sensorMutedUntil = Date.distantPast

    private var terminalActions: Bool {
        get { defaults.bool(forKey: "terminalActions") }
        set { defaults.set(newValue, forKey: "terminalActions") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        Paths.ensureDir()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = AppDelegate.whipIcon()
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        hotkey = Hotkey { [weak self] in self?.lash(force: 0.5, hard: false) }
        DistributedNotificationCenter.default().addObserver(forName: lashNotification, object: nil, queue: .main) { [weak self] note in
            let hard = note.object as? String == "hard"
            self?.lash(force: hard ? 1 : 0.5, hard: hard)
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshTitle() }
        refreshTitle()
        startSensorInProcess()
    }

    // MARK: Lash

    func lash(force: Double, hard: Bool) {
        sensorMutedUntil = Date().addingTimeInterval(1.0)
        let pending = StateStore.addLash(force: force, hard: hard)
        sound.play(force: hard ? 1 : force)
        WhipOverlay.lash(force: hard ? 1 : force, pending: pending)
        refreshTitle()

        guard terminalActions else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + WhipOverlay.duration) {
            if hard {
                TerminalKeys.interrupt()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { TerminalKeys.compact() }
            } else if pending >= 3 {
                TerminalKeys.interrupt()
            }
        }
    }

    private func sensorSlap(force: Double, hard: Bool) {
        guard Date() >= sensorMutedUntil else { return }
        lash(force: min(force, 1), hard: hard)
    }

    private func refreshTitle() {
        let n = StateStore.pendingCount()
        item.button?.title = n > 0 ? " \(n)" : ""
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            item.menu = buildMenu()
            item.button?.performClick(nil)
        } else {
            lash(force: 0.5, hard: false)
        }
    }

    func menuDidClose(_ menu: NSMenu) { item.menu = nil }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Lash (click icon or ⌃⌥W)", action: #selector(menuLash), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let hooked = Installer.isInstalled()
        let hooks = menu.addItem(withTitle: hooked ? "Claude Code hooks: on" : "Connect to Claude Code…", action: #selector(toggleHooks), keyEquivalent: "")
        hooks.target = self
        hooks.state = hooked ? .on : .off

        let slapTitle: String
        if !SlapSensor.isPresent { slapTitle = "Slap detection: not supported on this Mac" }
        else if sensorSeen || slapWatcher != nil { slapTitle = "Slap detection: on" }
        else { slapTitle = "Turn on slap detection…" }
        let slap = menu.addItem(withTitle: slapTitle, action: SlapSensor.isPresent && !sensorSeen && slapWatcher == nil ? #selector(enableSlaps) : nil, keyEquivalent: "")
        slap.target = self
        slap.state = sensorSeen || slapWatcher != nil ? .on : .off

        let term = menu.addItem(withTitle: "Esc on 3 lashes, /compact on a hard slap", action: #selector(toggleTerminal), keyEquivalent: "")
        term.target = self
        term.state = terminalActions ? .on : .off

        menu.addItem(.separator())
        let total = StateStore.read().total
        menu.addItem(withTitle: "Lashes all time: \(total)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Quit SlapShip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func menuLash() { lash(force: 0.5, hard: false) }

    @objc private func toggleHooks() {
        do {
            if Installer.isInstalled() { try Installer.uninstall() } else { try Installer.install() }
        } catch {
            alert("Couldn't update ~/.claude/settings.json", error.localizedDescription)
        }
    }

    @objc private func toggleTerminal() {
        terminalActions.toggle()
        if terminalActions && !TerminalKeys.hasPermission { TerminalKeys.askPermission() }
    }

    // MARK: Slap sensor

    /// Tries to read the sensor without root. Works only if something already woke it up.
    private func startSensorInProcess() {
        guard SlapSensor.isPresent else { return }
        let s = SlapSensor()
        s.onSample = { [weak self] _ in self?.sensorSeen = true }
        s.onSlap = { [weak self] slap in self?.sensorSlap(force: slap.force, hard: slap.hard) }
        guard s.start() else { return }
        sensor = s
    }

    /// Starts the root helper through the standard admin password prompt and follows its slap log.
    @objc private func enableSlaps() {
        if sensorSeen { return }
        sensor = nil
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let log = Paths.slaps.path
        FileManager.default.createFile(atPath: log, contents: nil)
        watchSlapLog()

        let cmd = "'\(exe)' sensor --out '\(log)' --parent \(getpid()) >/dev/null 2>&1 &"
        let script = "do shell script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            slapWatcher?.cancel()
            slapWatcher = nil
            alert("Slap detection is off", (error[NSAppleScript.errorMessage] as? String) ?? "The password prompt was cancelled.")
        }
    }

    private func watchSlapLog() {
        let fd = open(Paths.slaps.path, O_EVTONLY)
        guard fd >= 0 else { return }
        slapOffset = (try? FileManager.default.attributesOfItem(atPath: Paths.slaps.path)[.size] as? UInt64) ?? 0
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write], queue: .main)
        src.setEventHandler { [weak self] in self?.readNewSlaps() }
        src.setCancelHandler { close(fd) }
        src.resume()
        slapWatcher = src
    }

    private func readNewSlaps() {
        guard let h = FileHandle(forReadingAtPath: Paths.slaps.path) else { return }
        defer { try? h.close() }
        h.seek(toFileOffset: slapOffset)
        let data = h.readDataToEndOfFile()
        slapOffset += UInt64(data.count)
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let force = Double(parts[1]) else { continue }
            sensorSlap(force: force, hard: force >= SlapSensor.defaultHardThreshold)
        }
    }

    // MARK: Helpers

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// Small template whip: a handle and a curling lash.
    static func whipIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 15.5, y: 1.5))
            handle.line(to: NSPoint(x: 11.5, y: 6))
            handle.lineWidth = 3
            handle.lineCapStyle = .round
            handle.stroke()
            let lash = NSBezierPath()
            lash.move(to: NSPoint(x: 11.5, y: 6))
            lash.curve(to: NSPoint(x: 3, y: 9), controlPoint1: NSPoint(x: 8, y: 11), controlPoint2: NSPoint(x: 2, y: 15))
            lash.curve(to: NSPoint(x: 7, y: 6.5), controlPoint1: NSPoint(x: 4, y: 4), controlPoint2: NSPoint(x: 6, y: 5))
            lash.lineWidth = 1.4
            lash.lineCapStyle = .round
            lash.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}
