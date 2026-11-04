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
                try Self.rejectWriteACL(current)
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
        try Self.rejectWriteACL(file)
        return info
    }

    /// POSIX mode bits alone do not exclude macOS ACL write grants. Reject
    /// write-capable allow entries (including inheritable ones); deny/read-only
    /// ACLs such as the standard home-directory delete restriction are safe.
    private static func rejectWriteACL(_ file: Int32, allAllow: Bool = false) throws {
        guard let acl = acl_get_fd_np(file, ACL_TYPE_EXTENDED) else {
            // On a valid open descriptor Darwin reports an absent extended ACL
            // as ENOENT. Other failures (including unsupported filesystems) fail closed.
            guard errno == ENOENT else { throw RegistrationError.insecureFile }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let writes: [acl_perm_t] = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                                   ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
        let mask = writes.reduce(UInt64(0)) { $0 | UInt64($1.rawValue) }
        var entry: acl_entry_t?
        var cursor = ACL_FIRST_ENTRY
        while true {
            errno = 0
            if acl_get_entry(acl, cursor.rawValue, &entry) != 0 {
                guard errno == EINVAL else { throw RegistrationError.insecureFile }
                return
            }
            cursor = ACL_NEXT_ENTRY
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_mask_t = 0
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset_mask_np(entry, &permissions) == 0 else {
                throw RegistrationError.insecureFile
            }
            guard tag != ACL_EXTENDED_ALLOW || (!allAllow && permissions & mask == 0) else { throw RegistrationError.insecureFile }
        }
    }

    /// Secret-bearing directories must also reject read/traverse ACL grants,
    /// which can override 0700. Ancestors may retain ordinary read-only ACLs.
    func requirePrivate() throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == owner, info.st_mode & 0o077 == 0 else {
            throw RegistrationError.insecureFile
        }
        try requireNoAllowACL()
    }

    func requireNoAllowACL() throws { try Self.rejectWriteACL(descriptor, allAllow: true) }

    private init(descriptor: Int32, path: String, owner: uid_t) {
        self.descriptor = descriptor; self.path = path; self.owner = owner
    }

    func privateChild(_ name: String, create: Bool = false, exclusive: Bool = false) throws -> SecureDirectory? {
        try validate(name)
        if create {
            if mkdirat(descriptor, name, 0o700) != 0 {
                guard errno == EEXIST, !exclusive else { throw RegistrationError.insecureFile }
            } else if fsync(descriptor) != 0 { throw ResourceStoreError.io }
        }
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if child < 0, errno == ENOENT { return nil }
        guard child >= 0 else { throw RegistrationError.insecureFile }
        let result = SecureDirectory(descriptor: child, path: path + "/" + name, owner: owner)
        try result.requirePrivate()
        return result
    }

    func entries(limit: Int = 64) throws -> [String] {
        // Open a new description; dup would share and advance our dir offset.
        let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { throw ResourceStoreError.io }
        guard let stream = fdopendir(copy) else { close(copy); throw ResourceStoreError.io }
        defer { closedir(stream) }
        var names = [String]()
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ResourceStoreError.io }
                return names.sorted()
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            if name == "." || name == ".." { continue }
            guard names.count < limit else { throw RegistrationError.oversized }
            names.append(name)
        }
    }

    /// Only used after the UUID job is confirmed removed. The core creates a
    /// 0666 Unix socket inside this private directory, not a regular file.
    func requireOwnedSocket(_ name: String) throws {
        try validate(name)
        try requirePrivate()
        var st = stat()
        guard fstatat(descriptor, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
              st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == owner, st.st_nlink == 1 else {
            throw RegistrationError.insecureFile
        }
    }

    func removeOwnedSocket(_ name: String) throws {
        try requireOwnedSocket(name)
        guard unlinkat(descriptor, name, 0) == 0, fsync(descriptor) == 0 else { throw ResourceStoreError.io }
    }

    func removeRegularFile(_ name: String) throws {
        guard try withFile(name, { _ in true }) == true else { return }
        guard unlinkat(descriptor, name, 0) == 0, fsync(descriptor) == 0 else { throw ResourceStoreError.io }
    }

    func removeEmptyChild(_ name: String, matching child: SecureDirectory) throws {
        try validate(name)
        var expected = stat(), current = stat()
        guard fstat(child.descriptor, &expected) == 0,
              fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFDIR, current.st_ino == expected.st_ino, current.st_dev == expected.st_dev else {
            throw RegistrationError.insecureFile
        }
        guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0, fsync(descriptor) == 0 else { throw ResourceStoreError.io }
    }

    func requirePrivateFile(_ name: String) throws {
        _ = try withFile(name) { file in
            let info = try validateFile(file)
            guard info.st_mode & 0o077 == 0 else { throw RegistrationError.insecureFile }
            try Self.rejectWriteACL(file, allAllow: true)
        }
    }

    /// Callers retain the descriptor while checking/using the file. Paths and
    /// file names from clients must never reach this method.
    func withFile<T>(_ name: String, _ body: (Int32) throws -> T) throws -> T? {
        try validate(name)
        let file = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw RegistrationError.insecureFile }
        defer { close(file) }
        _ = try validateFile(file)
        return try body(file)
    }

    func withTemporaryFile<T>(_ body: (Int32, String) throws -> T) throws -> T {
        let name = ".staging-" + UUID().uuidString
        let file = openat(descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw ResourceStoreError.io }
        defer { close(file); unlinkat(descriptor, name, 0) }
        _ = try validateFile(file)
        return try body(file, name)
    }

    /// Hold this handle for the lifetime of the writer; kernel flock releases
    /// it if the service crashes. A second process cannot clean live staging.
    func acquireLock(_ name: String) throws -> FileHandle {
        try validate(name)
        let file = openat(descriptor, name, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard file >= 0 else { throw RegistrationError.insecureFile }
        do {
            _ = try validateFile(file)
            guard flock(file, LOCK_EX | LOCK_NB) == 0 else { throw ResourceStoreError.busy }
            return FileHandle(fileDescriptor: file, closeOnDealloc: true)
        } catch { close(file); throw error }
    }

    /// Only under the store's lifetime lock. Never traverse directories or
    /// delete an unrecognized entry while recovering interrupted transfers.
    func discardStagingFiles() throws {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw ResourceStoreError.io }
        guard let stream = fdopendir(copy) else { close(copy); throw ResourceStoreError.io }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ResourceStoreError.io }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard name.hasPrefix(".staging-"), UUID(uuidString: String(name.dropFirst(9))) != nil else { continue }
            _ = try withFile(name) { _ in () }
            guard unlinkat(descriptor, name, 0) == 0 else { throw ResourceStoreError.io }
        }
        guard fsync(descriptor) == 0 else { throw ResourceStoreError.io }
    }

    /// Publish only after the root-owned candidate has passed all checks.
    func publish(_ name: String, mode: mode_t, prepare: (Int32) throws -> Void) throws {
        try validate(name)
        _ = try withFile(name) { _ in () }
        try withTemporaryFile { file, temporary in
            try prepare(file)
            guard fchmod(file, mode) == 0, fsync(file) == 0 else { throw ResourceStoreError.io }
            _ = try withFile(name) { _ in () }
            guard renameat(descriptor, temporary, descriptor, name) == 0, fsync(descriptor) == 0 else {
                throw ResourceStoreError.io
            }
        }
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
