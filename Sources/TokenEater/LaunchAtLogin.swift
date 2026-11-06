import AppKit
import Foundation

enum LaunchAtLogin {
    static let label = "local.tokeneater.widget"
    private static let configuredKey = "launchAtLoginConfigured"

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func enableByDefaultIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: configuredKey) else { return }
        do {
            try setEnabled(true)
            defaults.set(true, forKey: configuredKey)
        } catch {
            return
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        UserDefaults.standard.set(true, forKey: configuredKey)
        if enabled {
            guard let executable = Bundle.main.executableURL?.path else {
                throw CocoaError(.fileNoSuchFile)
            }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive",
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            let directory = plistURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }
}

enum AppInstaller {
    /// Copies a click-launched copy into Applications and reopens that one.
    /// Returns true when this process is handing off and should not show the widget.
    static func relocateIfNeeded() -> Bool {
        let current = Bundle.main.bundleURL.standardizedFileURL
        guard let destination = installDestination(otherThan: current) else { return false }
        let identifier = Bundle.main.bundleIdentifier ?? LaunchAtLogin.label
        let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains {
            $0.bundleURL?.standardizedFileURL.path == destination.path
        }
        if !alreadyRunning {
            do {
                let manager = FileManager.default
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                try manager.copyItem(at: current, to: destination)
            } catch {
                return false
            }
        }
        NSWorkspace.shared.open(destination)
        NSApp.terminate(nil)
        return true
    }

    static func isDuplicateInstance() -> Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let identifier = Bundle.main.bundleIdentifier ?? LaunchAtLogin.label
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains {
            $0.processIdentifier != pid && $0.bundleURL?.standardizedFileURL.path == path
        }
    }

    private static func installDestination(otherThan current: URL) -> URL? {
        let system = URL(fileURLWithPath: "/Applications/TokenEater.app").standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/TokenEater.app")
            .standardizedFileURL
        if current.path == system.path || current.path == home.path {
            return nil
        }
        if FileManager.default.isWritableFile(atPath: "/Applications") {
            return system
        }
        try? FileManager.default.createDirectory(
            at: home.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return home
    }
}
