import Darwin
import Foundation

/// Descriptor-relative operations in an owner-controlled directory. Existing
/// directories and files are validated, never silently chmod/chowned into trust.
final class SecureDirectory {
    let path: String
    let owner: uid_t
    let descriptor: Int32

    init(path: String, owner: uid_t, create: Bool = false, mode: mode_t = 0o700) throws {
        let components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw RegistrationError.insecureFile }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw RegistrationError.insecureFile }
        do {
            for (index, component) in components.enumerated() {
                var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                if next < 0, errno == ENOENT, create, index == components.count - 1 {
                    guard mkdirat(current, component, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    guard fsync(current) == 0 else { throw POSIXError(.EIO) }
                    next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard next >= 0 else { throw RegistrationError.insecureFile }
                close(current)
                current = next
                var info = stat()
                guard fstat(current, &info) == 0, (info.st_uid == owner || info.st_uid == 0), info.st_mode & 0o022 == 0 else {
                    throw RegistrationError.insecureFile
                }
            }
        } catch { close(current); throw error }
        self.path = path
        self.owner = owner
        self.descriptor = current
    }

    deinit { close(descriptor) }

    private func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw RegistrationError.insecureFile
        }
    }

    private func validateFile(_ file: Int32) throws -> stat {
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
              info.st_mode & 0o022 == 0, info.st_nlink == 1 else { throw RegistrationError.insecureFile }
        return info
    }

    func read(_ name: String, limit: Int) throws -> Data? {
        try validate(name)
        let file = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw RegistrationError.insecureFile }
        defer { close(file) }
        let info = try validateFile(file)
        guard info.st_size <= limit else { throw RegistrationError.oversized }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(file, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.EIO)
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw RegistrationError.oversized }
        }
    }

    func write(_ name: String, data: Data, mode: mode_t) throws {
        try validate(name)
        // Refuse replacing an existing symlink, hard link or untrusted file.
        _ = try read(name, limit: InstallationPayload.maximumBinaryBytes)
        let temporary = ".staging-" + UUID().uuidString
        let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw POSIXError(.EIO) }
        defer { close(file); unlinkat(descriptor, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                written += count
            }
        }
        guard fchmod(file, mode) == 0, fsync(file) == 0,
              renameat(descriptor, temporary, descriptor, name) == 0, fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    func remove(_ name: String) throws {
        guard try read(name, limit: InstallationPayload.maximumBinaryBytes) != nil else { return }
        guard unlinkat(descriptor, name, 0) == 0, fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        let file = openat(descriptor, "install.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard file >= 0 else { throw RegistrationError.insecureFile }
        defer { close(file) }
        _ = try validateFile(file)
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else { throw InstallationError.busy }
        defer { flock(file, LOCK_UN) }
        return try body()
    }
}
