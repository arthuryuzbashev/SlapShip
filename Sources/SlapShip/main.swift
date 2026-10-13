import AppKit

let lashNotification = Notification.Name("app.slapship.lash")

let args = CommandLine.arguments

switch args.dropFirst().first {
case "hook":
    exit(Hook.run())
case "sensor":
    exit(SensorCommand.run(Array(args.dropFirst(2))))
case "install-hooks":
    do { try Installer.install(); print("Hooks added to \(Paths.claudeSettings.path)") } catch { print(error); exit(1) }
case "uninstall-hooks":
    do { try Installer.uninstall(); print("Hooks removed") } catch { print(error); exit(1) }
case "lash":
    // For scripts, Raycast, Stream Deck: asks the running app to lash.
    // `--queue` only queues the lash for Claude, without the app.
    if args.contains("--queue") {
        print("pending: \(StateStore.addLash(force: 0.5, hard: args.contains("--hard")))")
    } else {
        DistributedNotificationCenter.default().postNotificationName(
            lashNotification, object: args.contains("--hard") ? "hard" : nil, userInfo: nil, deliverImmediately: true)
    }
default:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
