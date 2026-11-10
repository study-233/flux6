import Darwin
import Foundation

/// Read an installation record through one descriptor, with no symlink or
/// writable ancestor through which another user could substitute its contents.
public enum RegistrationFile {
    public static func load(path: String, owner: uid_t, service: CodeIdentity) throws -> ServiceRegistration {
        let components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), components.count > 1,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw RegistrationError.insecureFile
        }

        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw RegistrationError.insecureFile }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw RegistrationError.insecureFile }
            close(directory)
            directory = next
            var info = stat()
            guard fstat(directory, &info) == 0,
                  (info.st_uid == 0 || info.st_uid == owner), info.st_mode & 0o022 == 0 else {
                throw RegistrationError.insecureFile
            }
        }

        // NONBLOCK avoids hanging on a substituted FIFO before fstat can reject it.
        let file = openat(directory, components.last!, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw RegistrationError.insecureFile }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == owner, info.st_mode & 0o022 == 0, info.st_nlink == 1 else {
            throw RegistrationError.insecureFile
        }
        guard info.st_size <= ServiceRegistration.maximumBytes else { throw RegistrationError.oversized }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(file, &buffer, min(buffer.count, ServiceRegistration.maximumBytes + 1 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw RegistrationError.insecureFile
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= ServiceRegistration.maximumBytes else { throw RegistrationError.oversized }
        }
        let registration = try ServiceRegistration.decode(data)
        guard registration.service == service else { throw RegistrationError.serviceIdentityMismatch }
        return registration
    }
}
