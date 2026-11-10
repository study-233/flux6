import Darwin
import Foundation

/// Ordinary-user boundary. Only the compiled manifest locates download files;
/// the service receives descriptors and independently verifies their contents.
public enum ServiceResourceTransfer {
    public static func prepare(cache: URL, runtimeID: String, geodataID: String, identity: CodeIdentity,
                               name: String = ServiceProtocolVersion.machService, privileged: Bool = true) throws {
        try ApprovedResourceCatalog.requirePair(runtimeID: runtimeID, geodataID: geodataID)
        _ = try ServiceClient.handshake(identity: identity, name: name, privileged: privileged)
        let present = try ServiceClient.resources(identity: identity, name: name, privileged: privileged)
        for asset in ApprovedResourceCatalog.native {
            try Task.checkCancellation()
            guard !present.contains(where: { $0.id == asset.id && $0.available }) else { continue }
            let source = try openSource(cache: cache, asset: asset)
            defer { try? source.close() }
            try ServiceClient.installResource(id: asset.id, source: source, identity: identity, name: name, privileged: privileged)
        }
        try Task.checkCancellation()
        guard try ServiceClient.resources(identity: identity, name: name, privileged: privileged).allSatisfy(\.available) else {
            throw ResourceStoreError.integrity
        }
    }

    static func openSource(cache: URL, asset: ApprovedResource) throws -> FileHandle {
        let directory: URL
        let name: String
        if let digest = asset.archiveSHA256, let archive = asset.archiveName {
            directory = cache.appendingPathComponent("runtime/" + digest)
            name = archive
        } else {
            let parts = asset.id.split(separator: "/")
            guard parts.count == 2, parts[0].hasPrefix("geodata-") else { throw ResourceStoreError.unapproved }
            directory = cache.appendingPathComponent("geodata/" + String(parts[0].dropFirst(8)))
            name = String(parts[1])
        }
        let folder = try SecureDirectory(path: directory.path, owner: geteuid(), searchAncestors: true)
        guard let handle = try folder.withFile(name, { source -> FileHandle in
            let file = fcntl(source, F_DUPFD_CLOEXEC, 3)
            guard file >= 0 else { throw ResourceStoreError.invalidSource }
            return FileHandle(fileDescriptor: file, closeOnDealloc: true)
        }) else { throw ResourceStoreError.invalidSource }
        return handle
    }
}
