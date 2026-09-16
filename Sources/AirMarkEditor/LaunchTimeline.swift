import AppKit
import Darwin

/// Records launch milestones relative to the process start time reported by the kernel and appends
/// them as one JSON line. Enabled only when AIRMARK_LAUNCH_LOG is set; used by Scripts/measure.sh.
@MainActor public final class LaunchTimeline {
    public let logURL: URL
    public let quitsWhenComplete: Bool
    private let processStart: Date
    private var milestones: [String: Double] = [:]
    private var written = false

    public init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment["AIRMARK_LAUNCH_LOG"] else { return nil }
        logURL = URL(fileURLWithPath: path)
        quitsWhenComplete = environment["AIRMARK_QUIT_AFTER_LAUNCH"] == "1"
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        processStart = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
    /// Milliseconds since process start; the first mark for a name wins.
    public func mark(_ name: String) {
        guard milestones[name] == nil else { return }
        milestones[name] = (Date().timeIntervalSince(processStart) * 1000 * 10).rounded() / 10
        if name == "firstParse" {
            // Give renders a moment to land, then record whatever happened.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                self?.finish()
            }
        }
    }
    public func finish() {
        guard !written else { return }
        written = true
        var record: [String: Any] = milestones
        let url = NSDocumentController.shared.documents.first?.fileURL
        record["document"] = url?.lastPathComponent ?? ""
        record["bytes"] = url.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int } ?? 0
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            let line = data + Data("\n".utf8)
            if let handle = try? FileHandle(forWritingTo: logURL) { handle.seekToEndOfFile(); handle.write(line); try? handle.close() }
            else { try? line.write(to: logURL) }
        }
        if quitsWhenComplete { NSApp.terminate(nil) }
    }
}
