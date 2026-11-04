import Foundation
import FreeV6Configuration

public typealias WarpRegistrationOperation = @Sendable (String, @escaping @Sendable (WorkerProgress) -> Void) async throws -> WarpCredential

public struct WarpAccountSummary: Sendable, Equatable {
    public let revision: UUID
    public let registeredAt: String
    init(_ stored: StoredWarpCredential) { revision = stored.revision; registeredAt = stored.credential.device.registeredAt }
}

public enum RegistrationWorkflowError: Error, LocalizedError, Sendable {
    case busy, pendingCredential, noPendingCredential
    public var errorDescription: String? {
        switch self {
        case .busy: return "凭据操作正在进行，请稍候。"
        case .pendingCredential: return "新凭据尚未保存。请先重试保存或放弃这次结果。"
        case .noPendingCredential: return "当前没有待保存的凭据。"
        }
    }
}

// Keep newly created credentials in memory if Keychain authorization or writes
// fail. Retrying storage must not create another remote WARP device.
public actor WarpRegistration {
    private let vault: WarpCredentialVault
    private let operation: WarpRegistrationOperation
    private var pending: WarpCredential?
    private var expectedRevision: UUID?
    private var busy = false
    public var hasPendingCredential: Bool { pending != nil }

    public init(vault: WarpCredentialVault, operation: @escaping WarpRegistrationOperation) {
        self.vault = vault; self.operation = operation
    }

    public func inspect() async throws -> WarpAccountSummary? {
        guard !busy else { throw RegistrationWorkflowError.busy }
        busy = true; defer { busy = false }
        return try await vault.load().map(WarpAccountSummary.init)
    }

    // Serialize use of a saved credential with replacement/deletion. Send only
    // tunnel material, never the account token, and recheck the saved revision
    // after asynchronous work so an externally replaced entry is not accepted.
    public func withSavedTunnel<Value: Sendable>(revision: UUID,
        operation: @Sendable (TunnelCredential) async throws -> Value) async throws -> Value {
        guard !busy else { throw RegistrationWorkflowError.busy }
        guard pending == nil else { throw RegistrationWorkflowError.pendingCredential }
        busy = true; defer { busy = false }
        guard let stored = try await vault.load(), stored.revision == revision else { throw CredentialError.conflict }
        try Task.checkCancellation()
        let result = try await operation(stored.credential.tunnelCredential())
        try Task.checkCancellation()
        guard try await vault.load()?.revision == revision else { throw CredentialError.conflict }
        return result
    }

    public func register(name: String, replacing revision: UUID?, willSave: @escaping @Sendable () -> Void = {}, progress: @escaping @Sendable (WorkerProgress) -> Void) async throws -> WarpAccountSummary {
        guard !busy else { throw RegistrationWorkflowError.busy }
        guard pending == nil else { throw RegistrationWorkflowError.pendingCredential }
        busy = true; defer { busy = false }
        // Verify access and replacement consent before contacting the service.
        let previous = try await vault.load()
        guard previous?.revision == revision else { throw CredentialError.conflict }
        try Task.checkCancellation()
        let credential = try await operation(name, progress).validated()
        pending = credential; expectedRevision = previous?.revision
        try Task.checkCancellation()
        willSave()
        return try await savePending()
    }

    public func retrySave() async throws -> WarpAccountSummary {
        guard !busy else { throw RegistrationWorkflowError.busy }
        busy = true; defer { busy = false }
        return try await savePending()
    }

    private func savePending() async throws -> WarpAccountSummary {
        guard let pending else { throw RegistrationWorkflowError.noPendingCredential }
        let stored = try await vault.save(pending, expectedRevision: expectedRevision)
        self.pending = nil; expectedRevision = nil
        return WarpAccountSummary(stored)
    }

    public func discardPending() throws {
        guard !busy else { throw RegistrationWorkflowError.busy }
        pending = nil; expectedRevision = nil
    }

    public func delete(revision: UUID) async throws {
        guard !busy else { throw RegistrationWorkflowError.busy }
        guard pending == nil else { throw RegistrationWorkflowError.pendingCredential }
        busy = true; defer { busy = false }
        try await vault.delete(expectedRevision: revision)
    }
}
