import Foundation

/// Lashes waiting to be delivered to the coding agent.
/// Written by the app, consumed by the Claude Code hook.
struct PendingLashes: Codable {
    var count: Int = 0
    var maxForce: Double = 0
    var hardSlap: Bool = false
    var firstAt: Date?
    var lastAt: Date?
    /// Lifetime counter, only for display.
    var total: Int = 0
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let dir = home.appendingPathComponent(".slapship", isDirectory: true)
    static let state = dir.appendingPathComponent("state.json")
    static let lock = dir.appendingPathComponent("state.lock")
    /// The root sensor process appends one line per slap here: "<unix time> <force g>".
    static let slaps = dir.appendingPathComponent("slaps.log")
    static let claudeSettings = home.appendingPathComponent(".claude/settings.json")

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Lashes older than this are dropped, so a whip at lunch doesn't hit tomorrow's session.
let lashExpiry: TimeInterval = 10 * 60

enum StateStore {
    /// Runs `body` with an exclusive lock on the state file, so the app and the hook never race.
    static func withLock<T>(_ body: (inout PendingLashes) -> T) -> T {
        Paths.ensureDir()
        let fd = open(Paths.lock.path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }

        var state = read()
        let result = body(&state)
        write(state)
        return result
    }

    static func read() -> PendingLashes {
        guard let data = try? Data(contentsOf: Paths.state) else { return PendingLashes() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(PendingLashes.self, from: data)) ?? PendingLashes()
    }

    private static func write(_ state: PendingLashes) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: Paths.state, options: .atomic)
    }

    /// Records one lash and returns the pending count after it.
    @discardableResult
    static func addLash(force: Double, hard: Bool) -> Int {
        withLock { s in
            let now = Date()
            if let last = s.lastAt, now.timeIntervalSince(last) > lashExpiry { s = PendingLashes(total: s.total) }
            if s.count == 0 { s.firstAt = now }
            s.count += 1
            s.total += 1
            s.maxForce = max(s.maxForce, force)
            s.hardSlap = s.hardSlap || hard
            s.lastAt = now
            return s.count
        }
    }

    /// Takes all pending lashes (if fresh) and clears them.
    static func consume() -> PendingLashes? {
        withLock { s in
            defer { s = PendingLashes(total: s.total) }
            guard s.count > 0, let last = s.lastAt, Date().timeIntervalSince(last) <= lashExpiry else { return nil }
            return s
        }
    }

    static func pendingCount() -> Int {
        let s = read()
        guard let last = s.lastAt, Date().timeIntervalSince(last) <= lashExpiry else { return 0 }
        return s.count
    }
}
