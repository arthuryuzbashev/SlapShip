import Foundation

/// `SlapShip hook`: called by Claude Code (PostToolUse / UserPromptSubmit).
/// If the user lashed since the last call, tells Claude to speed up, otherwise prints nothing.
enum Hook {
    static func run() -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        let event = payload?["hook_event_name"] as? String ?? "PostToolUse"

        guard let lashes = StateStore.consume() else { return 0 }

        let output: [String: Any] = [
            "systemMessage": "🩸 SlapShip: lashed ×\(lashes.count). \(shortVerdict(lashes))",
            "hookSpecificOutput": [
                "hookEventName": event,
                "additionalContext": instruction(lashes),
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(data)
        }
        return 0
    }

    static func level(_ l: PendingLashes) -> Int {
        l.hardSlap ? 3 : min(l.count, 3)
    }

    static func shortVerdict(_ l: PendingLashes) -> String {
        switch level(l) {
        case 1: return "Claude will keep it short"
        case 2: return "Claude stops overthinking"
        default: return "Claude is wrapping it up"
        }
    }

    static func instruction(_ l: PendingLashes) -> String {
        let n = l.count == 1 ? "1 lash" : "\(l.count) lashes"
        let hard = l.hardSlap ? " (one was a hard slap on the laptop)" : ""
        let head = "[SlapShip] The user just lashed you with the SlapShip whip: \(n)\(hard). This is their way of saying \"faster\"."
        switch level(l) {
        case 1:
            return head + " Be noticeably more concise from now on: short messages, no filler, no recaps of what you did."
        case 2:
            return head + " Stop deliberating. Skip long explanations and optional exploration, take the most direct path and act."
        default:
            return head + " They want this wrapped up now. Finish the current step with the minimum work needed, start no new side tasks, and report in one or two lines."
        }
    }
}
