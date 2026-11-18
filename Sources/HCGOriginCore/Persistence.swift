import Foundation
import HCGOriginProtocol
#if canImport(os)
import os
#endif

public enum OriginPaths {
    /// `HCG_ORIGIN_DATA_DIR` overrides the default (used by tests and verification scripts).
    public static func dataDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["HCG_ORIGIN_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HCG Origin", isDirectory: true)
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/share/hcg-origin", isDirectory: true)
        #endif
    }
}

/// Non-secret state as JSON files, written atomically.
public final class JSONFileStore: @unchecked Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Wire.decoder().decode(T.self, from: data)
    }

    public func save<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = Wire.encoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    public func append(line: Data, to name: String) {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (line + Data("\n".utf8)).write(to: url, options: .atomic)
        }
    }

    public func readLines(_ name: String, last: Int) -> [Data] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).suffix(last).map { Data($0) }
    }
}

/// Diagnostic log. Messages must never contain invitation codes, secrets or tokens;
/// callers pass only identifiers, states and error descriptions.
public enum OriginLog {
    #if canImport(os)
    static let logger = Logger(subsystem: "com.hakmicapitalgroup.hcgorigin", category: "gateway")
    #endif
    public static func info(_ message: String) {
        #if canImport(os)
        logger.info("\(message, privacy: .public)")
        #else
        if ProcessInfo.processInfo.environment["HCG_ORIGIN_VERBOSE"] != nil { print("[origin] \(message)") }
        #endif
    }
    public static func error(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #else
        if ProcessInfo.processInfo.environment["HCG_ORIGIN_VERBOSE"] != nil { print("[origin][error] \(message)") }
        #endif
    }
}
