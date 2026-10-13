import Foundation
import IOKit
import IOKit.hid

/// Reads the undocumented Bosch BMI286 accelerometer on Apple Silicon MacBooks (M2+, M1 Pro)
/// through IOKit HID and turns sudden jolts into slaps.
/// Turning the sensor on (setting driver properties) needs root.
final class SlapSensor {
    struct Slap { let force: Double; let hard: Bool }

    private static let vendorPage = 0xFF00
    private static let usageAccel = 3
    private static let reportLength = 22
    private static let dataOffset = 6

    var onSlap: ((Slap) -> Void)?
    var onSample: ((Double) -> Void)?

    /// Deviation from the resting vector (in g) that counts as a slap / a hard slap.
    static let defaultThreshold = 0.3
    static let defaultHardThreshold = 0.9
    var threshold = defaultThreshold
    var hardThreshold = defaultHardThreshold
    var cooldown: TimeInterval = 0.35

    private var device: IOHIDDevice?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    private var baseline: (Double, Double, Double)?
    private var lastSlap = Date.distantPast
    private var peak = 0.0
    private var peakUntil: Date?

    static var isPresent: Bool {
        var found = false
        forEachService("AppleSPUHIDDevice") { svc in
            if intProp(svc, "PrimaryUsagePage") == vendorPage, intProp(svc, "PrimaryUsage") == usageAccel { found = true }
        }
        return found
    }

    /// Returns false if the device could not be opened.
    func start() -> Bool {
        // Wake the sensor up. Silently fails without root.
        SlapSensor.forEachService("AppleSPUHIDDriver") { svc in
            for (key, value) in [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 1000)] {
                IORegistryEntrySetCFProperty(svc, key as CFString, NSNumber(value: value))
            }
        }

        var opened = false
        SlapSensor.forEachService("AppleSPUHIDDevice") { svc in
            guard !opened,
                  SlapSensor.intProp(svc, "PrimaryUsagePage") == SlapSensor.vendorPage,
                  SlapSensor.intProp(svc, "PrimaryUsage") == SlapSensor.usageAccel,
                  let hid = IOHIDDeviceCreate(kCFAllocatorDefault, svc),
                  IOHIDDeviceOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }

            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(hid, buffer, 4096, { context, _, _, _, _, report, length in
                guard let context else { return }
                Unmanaged<SlapSensor>.fromOpaque(context).takeUnretainedValue().handle(report, length)
            }, context)
            IOHIDDeviceScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            device = hid
            opened = true
        }
        return opened
    }

    private func handle(_ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex) {
        guard length == SlapSensor.reportLength else { return }
        func axis(_ i: Int) -> Double {
            var raw: Int32 = 0
            memcpy(&raw, report + SlapSensor.dataOffset + i * 4, 4)
            return Double(Int32(littleEndian: raw)) / 65536
        }
        let v = (axis(0), axis(1), axis(2))

        // Slow-moving baseline tracks gravity and lid tilt, the deviation from it is the jolt.
        guard var b = baseline else { baseline = v; return }
        let dev = sqrt(pow(v.0 - b.0, 2) + pow(v.1 - b.1, 2) + pow(v.2 - b.2, 2))
        let k = 0.01
        b = (b.0 + k * (v.0 - b.0), b.1 + k * (v.1 - b.1), b.2 + k * (v.2 - b.2))
        baseline = b
        onSample?(dev)

        let now = Date()
        // Collect the peak for 40 ms after crossing the threshold, so one hit is reported once with its real force.
        if let until = peakUntil {
            peak = max(peak, dev)
            if now >= until {
                peakUntil = nil
                lastSlap = now
                let force = peak
                onSlap?(Slap(force: force, hard: force >= hardThreshold))
            }
        } else if dev >= threshold, now.timeIntervalSince(lastSlap) >= cooldown {
            peak = dev
            peakUntil = now.addingTimeInterval(0.04)
        }
    }

    // MARK: IOKit helpers

    private static func forEachService(_ name: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let svc = IOIteratorNext(iterator), svc != 0 {
            body(svc)
            IOObjectRelease(svc)
        }
    }

    private static func intProp(_ svc: io_service_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
    }
}

/// `SlapShip sensor [--out <file>] [--debug]`: runs the sensor (as root) and appends slaps to a file
/// the menu bar app watches. `--debug` prints live readings for tuning.
enum SensorCommand {
    static func run(_ args: [String]) -> Int32 {
        let debug = args.contains("--debug")
        let out = args.firstIndex(of: "--out").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }

        guard SlapSensor.isPresent else {
            FileHandle.standardError.write("No accelerometer on this Mac (needs Apple Silicon M2+ or M1 Pro).\n".data(using: .utf8)!)
            return 2
        }
        if debug { setvbuf(stdout, nil, _IOLBF, 0) }
        let sensor = SlapSensor()
        var lastPrint = Date()
        var maxDev = 0.0
        if debug {
            sensor.onSample = { dev in
                maxDev = max(maxDev, dev)
                if Date().timeIntervalSince(lastPrint) > 0.25 {
                    print(String(format: "peak %.3f g", maxDev))
                    maxDev = 0
                    lastPrint = Date()
                }
            }
        }
        sensor.onSlap = { slap in
            let line = String(format: "%.3f %.3f\n", Date().timeIntervalSince1970, slap.force)
            if debug { print(String(format: "SLAP %.3f g%@", slap.force, slap.hard ? " HARD" : "")) }
            guard let out else { return }
            if let h = FileHandle(forWritingAtPath: out) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                FileManager.default.createFile(atPath: out, contents: line.data(using: .utf8), attributes: [.posixPermissions: 0o644])
            }
        }
        guard sensor.start() else {
            FileHandle.standardError.write("Could not open the accelerometer. Run as root.\n".data(using: .utf8)!)
            return 1
        }
        // The app kills us on quit, but don't outlive it if it crashes either.
        if let parent = args.firstIndex(of: "--parent").flatMap({ Int32(args[$0 + 1]) }) {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                if kill(parent, 0) != 0 { exit(0) }
            }
        }
        CFRunLoopRun()
        return 0
    }
}
