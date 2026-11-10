import Foundation
import FreeV6UpdateSupport

public struct UpdateTransaction: Codable, Sendable {
    public let sourceBuild: UInt64
    public let release: UpdateRelease
    public let preparedAt: Date

    public init(sourceBuild: UInt64, release: UpdateRelease) throws {
        try release.validate(currentBuild: sourceBuild)
        self.sourceBuild = sourceBuild
        self.release = release
        preparedAt = Date()
    }

    public func verifyInstalledPayload(contents: URL, build: UInt64) throws {
        guard build == release.build else { throw UpdateFailure.incompatible }
        let metadata = try InstallationPayload.readSource(contents.appendingPathComponent("Resources/update-compatibility.json"), limit: 4096)
        let signed = try UpdateRelease.decode(metadata, currentBuild: sourceBuild)
        let catalog = try InstallationPayload.readSource(contents.appendingPathComponent("Resources/runtime-assets.json"), limit: 1024 * 1024)
        guard signed == release, InstallationPayload.digest(catalog) == release.runtimeCatalogSHA256 else { throw UpdateFailure.incompatible }
        try verifyService(at: contents.appendingPathComponent("Library/LaunchServices/dev.freev6.network-service"))
    }

    public func verifyService(at url: URL) throws {
        let service = try InstallationPayload.readSource(url, limit: InstallationPayload.maximumBinaryBytes)
        guard InstallationPayload.digest(service) == release.serviceSHA256 else { throw UpdateFailure.incompatible }
    }
}

public struct UpdateTransactionStore: Sendable {
    private let root: URL
    public init(root: URL) { self.root = root }

    private func directory() throws -> SecureDirectory {
        let parent = try SecureDirectory(path: root.path, owner: geteuid(), create: true, searchAncestors: true)
        try parent.requirePrivate()
        guard let child = try parent.privateChild("update-v1", create: true) else { throw UpdateFailure.installation }
        return child
    }

    public func save(_ record: UpdateTransaction) throws {
        try record.release.validate(currentBuild: record.sourceBuild)
        let folder = try directory()
        let lock = try folder.acquireLock("transaction.lock")
        defer { try? lock.close() }
        try folder.discardStagingFiles()
        let data = try JSONEncoder().encode(record)
        try folder.write("pending.json", data: data, mode: 0o600)
    }

    public func load() throws -> UpdateTransaction? {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("update-v1").path) else { return nil }
        guard let data = try directory().read("pending.json", limit: 8192) else { return nil }
        let record = try JSONDecoder().decode(UpdateTransaction.self, from: data)
        try record.release.validate(currentBuild: record.sourceBuild)
        return record
    }

    public func clear(targetBuild: UInt64) throws {
        let folder = try directory()
        let lock = try folder.acquireLock("transaction.lock")
        defer { try? lock.close() }
        guard let current = try load(), current.release.build == targetBuild else { return }
        try folder.remove("pending.json")
    }
}
