import Foundation

/// Discovery record the hook script reads. Fields match `ServerConfig`
/// (server/src/serverConfig.ts); `isServerConfig` rejects anything else.
public struct RegistryEntry: Codable, Equatable {
    public var port: Int
    public var pid: Int
    public var token: String
    public var startedAt: Int
    public var servesSpa: Bool
    public var protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case port, pid, token, startedAt, servesSpa
        case protocolVersion = "protocol"
    }

    public init(port: Int, pid: Int, token: String, startedAt: Int, servesSpa: Bool = false, protocolVersion: Int = 1) {
        self.port = port
        self.pid = pid
        self.token = token
        self.startedAt = startedAt
        self.servesSpa = servesSpa
        self.protocolVersion = protocolVersion
    }
}

/// `~/.pixel-agents/servers/menubar-<pid>.json`. The hook script fans each event out to
/// every live entry, so this coexists with the VS Code extension and `npx pixel-agents`.
public struct Registry {
    public let directory: URL
    static let prefix = "menubar-"

    public init(directory: URL = Registry.defaultDirectory) { self.directory = directory }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pixel-agents/servers", isDirectory: true)
    }

    public func fileURL(pid: Int) -> URL { directory.appendingPathComponent("\(Self.prefix)\(pid).json") }

    /// Atomic write, mode 0600 (the token is a bearer secret).
    public func write(_ entry: RegistryEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entry)
        let url = fileURL(pid: entry.pid)
        let tmp = directory.appendingPathComponent(".\(Self.prefix)\(entry.pid).tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    public func remove(pid: Int) {
        try? FileManager.default.removeItem(at: fileURL(pid: pid))
    }

    /// Entries written by other menu bar instances, live or not.
    public func existingEntries() -> [(url: URL, entry: RegistryEntry)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasPrefix(Self.prefix) && $0.hasSuffix(".json") }.compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(RegistryEntry.self, from: data) else { return nil }
            return (url, entry)
        }
    }

    /// Removes our own entries whose process is gone. Returns a live entry from another instance, if any.
    @discardableResult
    public func cleanStale(isAlive: (Int) -> Bool = Registry.processIsAlive) -> RegistryEntry? {
        var live: RegistryEntry?
        for (url, entry) in existingEntries() {
            if isAlive(entry.pid) {
                live = entry
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return live
    }

    public static func processIsAlive(_ pid: Int) -> Bool {
        // kill(pid, 0) succeeds if the process exists (EPERM also means it exists).
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}

public func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
    return bytes.map { String(format: "%02x", $0) }.joined()
}
