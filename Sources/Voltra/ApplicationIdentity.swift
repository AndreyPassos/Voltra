import Foundation
import AppKit
import Darwin

enum ApplicationIdentity {
    static func outermostAppURL(_ url: URL) -> URL? {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for part in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(part, isDirectory: true)
            if part.lowercased().hasSuffix(".app") { return current }
        }
        return nil
    }
    static func resolveExecutable(_ executable: URL) -> (id: String, name: String, bundleURL: URL)? {
        guard let root = outermostAppURL(executable), let bundle = Bundle(url: root), let identifier = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? root.deletingPathExtension().lastPathComponent
        return (identifier, name, root)
    }
    static func resolveProcess(_ pid: pid_t) -> (id: String, name: String, bundleURL: URL?)? {
        if let app = NSRunningApplication(processIdentifier: pid), let identity = resolve(app) {
            return (identity.id, identity.name, app.bundleURL.flatMap(outermostAppURL))
        }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              let identity = resolveExecutable(URL(fileURLWithPath: String(cString: path))) else { return nil }
        return (identity.id, identity.name, identity.bundleURL)
    }
    static func resolve(_ app: NSRunningApplication) -> (id: String, name: String)? {
        if let url = app.bundleURL, let root = outermostAppURL(url), let bundle = Bundle(url: root), let identifier = bundle.bundleIdentifier {
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? root.deletingPathExtension().lastPathComponent
            return (identifier, name)
        }
        guard let name = app.localizedName else { return nil }
        return (app.bundleIdentifier ?? "pid:\(app.processIdentifier)", name)
    }
}
