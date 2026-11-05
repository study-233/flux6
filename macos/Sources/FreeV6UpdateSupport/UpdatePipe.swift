import Darwin
import Foundation

public struct UpdateEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case checking, found, downloading, ready, installing, finished, failed }
    public let operation: UUID
    public let kind: Kind
    public let release: UpdateRelease?
    public let failure: UpdateFailure?

    public init(_ kind: Kind, operation: UUID, release: UpdateRelease? = nil, failure: UpdateFailure? = nil) {
        self.kind = kind
        self.operation = operation
        self.release = release
        self.failure = failure
    }
}

public struct UpdateReply: Codable, Sendable {
    public let operation: UUID
    public let install: Bool
    public init(operation: UUID, install: Bool) { self.operation = operation; self.install = install }
}

public enum UpdatePipe {
    private static let maximum = 16_384

    public static func write<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximum else { throw UpdateFailure.transport }
        var count = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &count) { Data($0) }
        frame.append(data)
        try handle.write(contentsOf: frame)
    }

    public static func read<T: Decodable>(_ type: T.Type, from handle: FileHandle) throws -> T? {
        guard let header = try exact(4, from: handle, allowsEOF: true) else { return nil }
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= maximum, let data = try exact(Int(count), from: handle) else { throw UpdateFailure.transport }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func exact(_ count: Int, from handle: FileHandle, allowsEOF: Bool = false) throws -> Data? {
        var result = Data()
        while result.count < count {
            guard let next = try handle.read(upToCount: count - result.count), !next.isEmpty else {
                if result.isEmpty && allowsEOF { return nil }
                throw UpdateFailure.transport
            }
            result.append(next)
        }
        return result
    }

    public static func requireInheritedPipes() throws {
        var input = stat(), output = stat()
        guard geteuid() != 0, fstat(STDIN_FILENO, &input) == 0, fstat(STDOUT_FILENO, &output) == 0,
              input.st_mode & S_IFMT == S_IFIFO, output.st_mode & S_IFMT == S_IFIFO else { throw UpdateFailure.invalidHost }
    }
}
