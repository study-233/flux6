import XCTest
import Security
@testable import FreeV6Business

private actor MemorySecretStorage: VersionedSecretStorage {
    var value: SecretSnapshot?
    var failWrites = false
    var readError: CredentialError?
    func setFailure(_ value: Bool) { failWrites = value }
    func setReadError(_ error: CredentialError?) { readError = error }
    func read() throws -> SecretSnapshot? {
        if let readError { throw readError }
        return value
    }
    func read(interactionAllowed: Bool) throws -> SecretSnapshot? { try read() }
    func write(_ data: Data, expectedRevision: UUID?, interactionAllowed: Bool) throws -> SecretSnapshot {
        try write(data, expectedRevision: expectedRevision)
    }
    func write(_ data: Data, expectedRevision: UUID?) throws -> SecretSnapshot {
        if failWrites { throw CredentialError.security(errSecUserCanceled) }
        guard value?.revision == expectedRevision else { throw CredentialError.conflict }
        let item = SecretSnapshot(revision: UUID(), data: data)
        value = item
        return item
    }
    func delete(expectedRevision: UUID) throws {
        guard value?.revision == expectedRevision else { throw CredentialError.conflict }
        value = nil
    }
}

private actor RegistrationCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor RegistrationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiter?.resume(); waiter = nil
        }
    }
    func untilWaiting() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class WarpCredentialTests: XCTestCase {
    private func fixture() throws -> WarpCredential {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(WarpCredential.self,
            from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/warp-credential.json")))
    }

    func testGoGeneratedSEC1AndSPKIFixtureAndInvalidCredentialRejection() async throws {
        let credential = try fixture().validated()
        XCTAssertEqual(credential.device.registeredAt, "2026-01-01T00:00:00.123456789Z")
        XCTAssertEqual(String(describing: credential), "WarpCredential(redacted)")
        let vault = WarpCredentialVault(storage: MemorySecretStorage())
        let saved = try await vault.save(credential, expectedRevision: nil)
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(credential)) as? [String: Any])
        var device = try XCTUnwrap(data["device"] as? [String: Any])
        device["privateKey"] = "invalid-sensitive-key"; data["device"] = device
        let bad = try JSONDecoder().decode(WarpCredential.self, from: JSONSerialization.data(withJSONObject: data))
        do { _ = try await vault.save(bad, expectedRevision: saved.revision); XCTFail("invalid key saved") }
        catch { XCTAssertEqual(error as? CredentialError, .invalidCredential) }
        let retained = try await vault.load()
        XCTAssertEqual(retained?.revision, saved.revision)
    }

    func testFailedSaveRetainsOldCredentialAndRetryDoesNotRegisterAgain() async throws {
        let credential = try fixture()
        let storage = MemorySecretStorage(), counter = RegistrationCounter()
        let vault = WarpCredentialVault(storage: storage)
        let old = try await vault.save(credential, expectedRevision: nil)
        let workflow = WarpRegistration(vault: vault) { _, _ in await counter.increment(); return credential }
        await storage.setFailure(true)
        do { _ = try await workflow.register(name: "Mac", replacing: old.revision) { _ in }; XCTFail("denied save succeeded") }
        catch { XCTAssertEqual(error as? CredentialError, .security(errSecUserCanceled)) }
        let pending = await workflow.hasPendingCredential
        XCTAssertTrue(pending)
        let retained = try await vault.load()
        XCTAssertEqual(retained?.revision, old.revision)
        do { _ = try await workflow.register(name: "Mac", replacing: old.revision) { _ in }; XCTFail("registered again with pending credential") }
        catch { XCTAssertTrue(error is RegistrationWorkflowError) }
        await storage.setFailure(false)
        let saved = try await workflow.retrySave()
        let count = await counter.value
        XCTAssertEqual(count, 1)
        XCTAssertNotEqual(saved.revision, old.revision)
        do { try await workflow.delete(revision: old.revision); XCTFail("stale deletion succeeded") }
        catch { XCTAssertEqual(error as? CredentialError, .conflict) }
        try await workflow.delete(revision: saved.revision)
        let empty = try await workflow.inspect()
        XCTAssertNil(empty)
    }

    func testExistingCredentialRequiresCurrentRevisionBeforeAnyRegistration() async throws {
        let credential = try fixture(), counter = RegistrationCounter()
        let vault = WarpCredentialVault(storage: MemorySecretStorage())
        _ = try await vault.save(credential, expectedRevision: nil)
        let workflow = WarpRegistration(vault: vault) { _, _ in await counter.increment(); return credential }
        for revision in [Optional<UUID>.none, UUID()] {
            do { _ = try await workflow.register(name: "Mac", replacing: revision) { _ in }; XCTFail("unapproved replacement accepted") }
            catch { XCTAssertEqual(error as? CredentialError, .conflict) }
        }
        let count = await counter.value
        XCTAssertEqual(count, 0)
    }

    func testMissingCredentialRegistersOnceAndReusesAcrossWorkflowInstances() async throws {
        let credential = try fixture(), storage = MemorySecretStorage(), counter = RegistrationCounter()
        let vault = WarpCredentialVault(storage: storage)
        let operation: WarpRegistrationOperation = { _, _ in await counter.increment(); return credential }
        let first = WarpRegistration(vault: vault, operation: operation)
        let created = try await first.ensureRegistered(interactionAllowed: false)
        let reused = try await first.ensureRegistered(interactionAllowed: true)
        let restarted = WarpRegistration(vault: WarpCredentialVault(storage: storage), operation: operation)
        let afterRestart = try await restarted.ensureRegistered(interactionAllowed: false)
        XCTAssertEqual(created, reused); XCTAssertEqual(created, afterRestart)
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testDeniedLockedOrDamagedCredentialNeverTriggersAutomaticRegistration() async throws {
        let credential = try fixture(), storage = MemorySecretStorage(), counter = RegistrationCounter()
        let workflow = WarpRegistration(vault: WarpCredentialVault(storage: storage)) { _, _ in
            await counter.increment(); return credential
        }
        for error in [CredentialError.security(errSecUserCanceled), .security(errSecInteractionNotAllowed),
                      .security(errSecAuthFailed), .invalidCredential] {
            await storage.setReadError(error)
            do { _ = try await workflow.ensureRegistered(interactionAllowed: false); XCTFail("Access failure ignored") }
            catch let received { XCTAssertEqual(received as? CredentialError, error) }
        }
        let count = await counter.value
        XCTAssertEqual(count, 0)
    }

    func testAutomaticSaveFailureRetainsOneDeviceAndSharesManualRetry() async throws {
        let credential = try fixture(), storage = MemorySecretStorage(), counter = RegistrationCounter()
        let workflow = WarpRegistration(vault: WarpCredentialVault(storage: storage)) { _, _ in
            await counter.increment(); return credential
        }
        await storage.setFailure(true)
        for _ in 0..<2 {
            do { _ = try await workflow.ensureRegistered(interactionAllowed: true); XCTFail("Save failure ignored") }
            catch { XCTAssertEqual(error as? CredentialError, .security(errSecUserCanceled)) }
        }
        let pending = await workflow.hasPendingCredential
        XCTAssertTrue(pending)
        await storage.setFailure(false)
        let saved = try await workflow.retrySave()
        let reused = try await workflow.ensureRegistered(interactionAllowed: false)
        XCTAssertEqual(saved, reused)
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testConcurrentEnsureAndManualRegistrationCannotCreateAnotherDevice() async throws {
        let credential = try fixture(), counter = RegistrationCounter()
        let vault = WarpCredentialVault(storage: MemorySecretStorage())
        let gate = RegistrationGate()
        let workflow = WarpRegistration(vault: vault) { _, _ in
            await counter.increment(); await gate.wait(); return credential
        }
        let first = Task { try await workflow.ensureRegistered(interactionAllowed: true) }
        await gate.untilWaiting()
        do { _ = try await workflow.ensureRegistered(interactionAllowed: true); XCTFail("Concurrent registration") }
        catch { XCTAssertTrue(error is RegistrationWorkflowError) }
        do { _ = try await workflow.register(name: "Mac", replacing: nil) { _ in }; XCTFail("Concurrent manual registration") }
        catch { XCTAssertTrue(error is RegistrationWorkflowError) }
        await gate.release()
        _ = try await first.value
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testAutomaticRegistrationNeverOverwritesAnExternallyCreatedCredential() async throws {
        let credential = try fixture(), storage = MemorySecretStorage()
        let vault = WarpCredentialVault(storage: storage)
        let workflow = WarpRegistration(vault: vault) { _, _ in
            _ = try await vault.save(credential, expectedRevision: nil)
            return credential
        }
        do { _ = try await workflow.ensureRegistered(interactionAllowed: true); XCTFail("Overwrite accepted") }
        catch { XCTAssertEqual(error as? CredentialError, .conflict) }
        let external = try await vault.load()
        XCTAssertNotNil(external)
        let pending = await workflow.hasPendingCredential
        XCTAssertTrue(pending)
        do { _ = try await workflow.ensureRegistered(interactionAllowed: true); XCTFail("Pending overwrote external item") }
        catch { XCTAssertEqual(error as? CredentialError, .conflict) }
        let retained = try await vault.load()
        XCTAssertEqual(external?.revision, retained?.revision)
    }

    func testCancelledAutomaticRegistrationRetainsReturnedDeviceForRetry() async throws {
        let credential = try fixture(), counter = RegistrationCounter(), gate = RegistrationGate()
        let workflow = WarpRegistration(vault: WarpCredentialVault(storage: MemorySecretStorage())) { _, _ in
            await counter.increment(); await gate.wait(); return credential
        }
        let first = Task { try await workflow.ensureRegistered(interactionAllowed: true) }
        await gate.untilWaiting(); first.cancel(); await gate.release()
        do { _ = try await first.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        _ = try await workflow.ensureRegistered(interactionAllowed: true)
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testFailedRegistrationCanBeRetriedWithoutSavingInvalidState() async throws {
        let credential = try fixture(), counter = RegistrationCounter()
        let vault = WarpCredentialVault(storage: MemorySecretStorage())
        let workflow = WarpRegistration(vault: vault) { _, _ in
            await counter.increment()
            if await counter.value == 1 { throw URLError(.notConnectedToInternet) }
            return credential
        }
        do { _ = try await workflow.ensureRegistered(interactionAllowed: true); XCTFail("Network failure ignored") }
        catch { XCTAssertTrue(error is URLError) }
        let saved = try await vault.load(), pending = await workflow.hasPendingCredential
        XCTAssertNil(saved); XCTAssertFalse(pending)
        _ = try await workflow.ensureRegistered(interactionAllowed: true)
        let count = await counter.value
        XCTAssertEqual(count, 2)
    }

    func testPrivateKeychainRoundTripAndRevisionConflicts() async throws {
        guard ProcessInfo.processInfo.environment["FREEV6_TEST_PRIVATE_KEYCHAIN"] == "1" else {
            throw XCTSkip("Opt in to an isolated temporary Keychain test; never uses login Keychain")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freev6-private-keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Process-local setting for this test host only. Never suppress a real
        // application's authorization prompt, and never unlock the login keychain.
        var previouslyAllowed = DarwinBoolean(true)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&previouslyAllowed), errSecSuccess)
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(false), errSecSuccess)
        defer { SecKeychainSetUserInteractionAllowed(previouslyAllowed.boolValue) }
        let password = Data(UUID().uuidString.utf8)
        var keychain: SecKeychain?
        let path = root.appendingPathComponent("test.keychain-db").path
        let status = path.withCString { path in password.withUnsafeBytes { bytes in
            SecKeychainCreate(path, UInt32(password.count), bytes.baseAddress, false, nil, &keychain)
        } }
        guard status == errSecSuccess, let keychain else { throw CredentialError.security(status) }
        defer { XCTAssertEqual(SecKeychainDelete(keychain), errSecSuccess) }
        let service = "dev.freev6.test.\(UUID().uuidString)"
        let storage = KeychainSecretStorage(service: service, account: "fixture", keychain: keychain)
        let otherStorage = KeychainSecretStorage(service: service, account: "fixture", keychain: keychain)
        let empty = try await storage.read()
        XCTAssertNil(empty)
        let first = try await storage.write(Data("synthetic first".utf8), expectedRevision: nil, interactionAllowed: false)
        let read = try await storage.read()
        XCTAssertEqual(read?.revision, first.revision)
        XCTAssertEqual(read?.data, first.data)
        let reads = try await storage.secretReadsForTesting()
        for _ in 0..<4 { _ = try await storage.read(interactionAllowed: false) }
        let reusedReads = try await storage.secretReadsForTesting()
        XCTAssertEqual(reusedReads, reads, "Repeated preparation must reuse authorized bytes, not request secret data again")
        do { _ = try await storage.write(Data("duplicate".utf8), expectedRevision: nil); XCTFail("duplicate insert replaced item") }
        catch { XCTAssertEqual(error as? CredentialError, .conflict) }
        // A second instance changes an entry that the first has cached. Reuse
        // must detect the new revision before returning any secret bytes.
        let second = try await otherStorage.write(Data("synthetic second".utf8), expectedRevision: first.revision)
        let external = try await storage.read(interactionAllowed: false)
        XCTAssertEqual(external?.revision, second.revision)
        XCTAssertEqual(external?.data, second.data)
        do { _ = try await storage.write(Data("stale".utf8), expectedRevision: first.revision); XCTFail("stale update replaced item") }
        catch { XCTAssertEqual(error as? CredentialError, .conflict) }
        do { try await storage.delete(expectedRevision: first.revision); XCTFail("stale deletion removed item") }
        catch { XCTAssertEqual(error as? CredentialError, .conflict) }
        let retained = try await storage.read()
        XCTAssertEqual(retained?.revision, second.revision)
        XCTAssertEqual(retained?.data, second.data)
        try await otherStorage.delete(expectedRevision: second.revision)
        let removed = try await storage.read()
        XCTAssertNil(removed)
        let chainStorage = KeychainSecretStorage(service: "dev.freev6.test.chain", account: "key", keychain: keychain)
        let keys = ChainProfileKey(storage: chainStorage)
        do { try await keys.checkAccess(); XCTFail("read-only check created a key") }
        catch { XCTAssertTrue(error.localizedDescription.contains("钥匙串密钥")) }
        let stillMissing = try await chainStorage.read()
        XCTAssertNil(stillMissing)
        let fresh = try await keys.load(allowCreation: true)
        let beforeCheck = try await chainStorage.read()
        try await keys.checkAccess()
        let afterCheck = try await chainStorage.read()
        XCTAssertEqual(beforeCheck?.revision, afterCheck?.revision)
        XCTAssertEqual(beforeCheck?.data, afterCheck?.data)
        let same = try await keys.load(allowCreation: false)
        XCTAssertEqual(fresh.count, 32)
        XCTAssertEqual(fresh, same)
        let silent = try await keys.load(allowCreation: false, interactionAllowed: false)
        XCTAssertEqual(fresh, silent)
        // Only this test keychain is locked. Start with UI enabled, so the
        // actual background read must suppress it and restore the prior flag.
        XCTAssertEqual(SecKeychainLock(keychain), errSecSuccess)
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(true), errSecSuccess)
        do {
            try await keys.checkAccess(interactionAllowed: false)
            XCTFail("A background read returned data from the locked keychain")
        } catch {
            XCTAssertEqual(error as? CredentialError, .security(errSecInteractionNotAllowed))
        }
        var allowed = DarwinBoolean(false)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
        XCTAssertTrue(allowed.boolValue)
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(false), errSecSuccess)
    }

    func testSavedTunnelRejectsStaleRevisionAndSerializesReplacement() async throws {
        let credential = try fixture()
        let vault = WarpCredentialVault(storage: MemorySecretStorage())
        let stored = try await vault.save(credential, expectedRevision: nil)
        let workflow = WarpRegistration(vault: vault) { _, _ in credential }
        do {
            let _: Int = try await workflow.withSavedTunnel(revision: UUID()) { _ in XCTFail("stale access reached operation"); return 0 }
            XCTFail("stale revision accepted")
        } catch { XCTAssertEqual(error as? CredentialError, .conflict) }
        let result = try await workflow.withSavedTunnel(revision: stored.revision) { tunnel in
            let encoded = String(decoding: try JSONEncoder().encode(tunnel), as: UTF8.self)
            XCTAssertFalse(encoded.contains("token")); XCTAssertFalse(encoded.contains("deviceId"))
            do { try await workflow.delete(revision: stored.revision); XCTFail("deleted during preparation") }
            catch { XCTAssertTrue(error is RegistrationWorkflowError) }
            return 42
        }
        XCTAssertEqual(result, 42)
        do {
            let _: Int = try await workflow.withSavedTunnel(revision: stored.revision) { _ in
                _ = try await vault.save(credential, expectedRevision: stored.revision)
                return 0
            }
            XCTFail("external credential replacement was not detected")
        } catch { XCTAssertEqual(error as? CredentialError, .conflict) }
        let current = try await workflow.inspect()
        XCTAssertNotEqual(current?.revision, stored.revision)
    }
}
