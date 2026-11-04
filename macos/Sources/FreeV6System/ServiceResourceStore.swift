import Darwin
import Foundation

/// Production uses the fixed root-owned ServicePaths.resources directory.
/// A different directory/owner is only supplied by local test hosts.
public final class ServiceResourceStore {
    private let directory: SecureDirectory
    private let lease: FileHandle
    private let lock = NSLock()

    public init(path: String = ServicePaths.resources, owner: uid_t = 0) throws {
        directory = try SecureDirectory(path: path, owner: owner, create: true)
        var info = stat()
        guard fstat(directory.descriptor, &info) == 0, info.st_uid == owner,
              info.st_mode & 0o077 == 0 else { throw RegistrationError.insecureFile }
        lease = try directory.acquireLock("resources.lock")
        try directory.discardStagingFiles()
    }

    public func install(id: String, source: FileHandle, clientUID: uid_t) throws -> ResourceAvailability {
        guard lock.try() else { throw ResourceStoreError.busy }
        defer { lock.unlock() }
        let asset = try ApprovedResourceCatalog.asset(id)
        let fd = fcntl(source.fileDescriptor, F_DUPFD_CLOEXEC, 3)
        guard fd >= 0 else { throw ResourceStoreError.invalidSource }
        defer { close(fd) }
        var info = stat()
        guard clientUID != 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == clientUID, info.st_mode & 0o022 == 0, info.st_nlink == 1 else {
            throw ResourceStoreError.invalidSource
        }
        let deadline = ResourceIO.deadline()
        try directory.withTemporaryFile { staged, _ in
            let expected = asset.archiveSHA256 ?? asset.sha256
            let limit = asset.archiveSHA256 == nil ? asset.limit : ApprovedResourceCatalog.maximumBytes
            try ResourceIO.scan(fd, destination: staged, limit: limit, expected: expected,
                                size: asset.archiveSHA256 == nil ? asset.size : nil, deadline: deadline)
            guard fsync(staged) == 0 else { throw ResourceStoreError.io }
            // Re-read the private copy; the client may still mutate its own fd.
            try ResourceIO.scan(staged, limit: limit, expected: expected, deadline: deadline)
            try directory.publish(asset.filename, mode: asset.mode) { candidate in
                if asset.archiveSHA256 != nil {
                    try ResourceIO.inflateGzip(staged, into: candidate, limit: asset.limit, deadline: deadline)
                } else {
                    try ResourceIO.scan(staged, destination: candidate, limit: asset.limit,
                                        expected: asset.sha256, size: asset.size, deadline: deadline)
                }
                guard fsync(candidate) == 0 else { throw ResourceStoreError.io }
                try verify(candidate, asset: asset, deadline: deadline)
            }
        }
        return ResourceAvailability(id: asset.id, available: true)
    }

    public func status() throws -> [ResourceAvailability] {
        guard lock.try() else { throw ResourceStoreError.busy }
        defer { lock.unlock() }
        return try statusUnlocked()
    }

    public func checkConfiguration(_ data: Data, clientUID: uid_t) throws -> ConfigurationCheckReply {
        guard clientUID != 0 else { throw ResourceStoreError.invalidSource }
        guard lock.try() else { throw ResourceStoreError.busy }
        defer { lock.unlock() }
        let request = try ServiceMessages.decodeConfiguration(data)
        guard try statusUnlocked().allSatisfy(\.available) else { throw ResourceStoreError.integrity }
        _ = try ServiceConfigurationAssembler.assemble(request.configuration, sessionID: UUID())
        // No private key, socket path, random secret, or assembled config escapes.
        return ConfigurationCheckReply(request)
    }

    /// Caller owns the preparation store's lifetime lease. No core is launched
    /// here; launch must first persist a newer journal schema with its intent.
    func prepareSession(_ data: Data, clientUID: uid_t, sessions: PreparedSessionStore) throws -> PreparedSessionRecord {
        guard clientUID != 0 else { throw SessionStoreError.wrongOwner }
        guard lock.try() else { throw ResourceStoreError.busy }
        defer { lock.unlock() }
        let request = try ServiceMessages.decodeConfiguration(data)
        return try sessions.prepare(request, clientUID: clientUID) { destination in
            let deadline = ResourceIO.deadline()
            for asset in ApprovedResourceCatalog.native {
                guard try directory.withFile(asset.filename, { source in
                    // Copy while hashing, then independently re-read the new
                    // inode. No hard links or paths into the mutable cache.
                    try destination.publish(PreparedSessionStore.filename(asset), mode: asset.mode) { candidate in
                        try ResourceIO.scan(source, destination: candidate, limit: asset.limit,
                            expected: asset.sha256, size: asset.size, deadline: deadline)
                        guard fsync(candidate) == 0 else { throw ResourceStoreError.io }
                        try verify(candidate, asset: asset, deadline: deadline)
                    }
                    return true
                }) == true else { throw ResourceStoreError.integrity }
            }
        }
    }

    private func statusUnlocked() throws -> [ResourceAvailability] {
        let deadline = ResourceIO.deadline()
        return try ApprovedResourceCatalog.native.map { asset in
            try ResourceIO.checkDeadline(deadline)
            let available = try directory.withFile(asset.filename) { file in
                do { try verify(file, asset: asset, deadline: deadline); return true }
                catch ResourceStoreError.integrity { return false }
                catch ResourceStoreError.tooLarge { return false }
            } ?? false
            return ResourceAvailability(id: asset.id, available: available)
        }
    }

    private func verify(_ file: Int32, asset: ApprovedResource, deadline: UInt64) throws {
        try ResourceIO.scan(file, limit: asset.limit, expected: asset.sha256, size: asset.size, deadline: deadline)
        if let arch = asset.architecture { try ResourceIO.verifyMachO(file, architecture: arch) }
    }
}
