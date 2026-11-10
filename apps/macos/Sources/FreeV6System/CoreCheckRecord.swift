import Darwin
import Foundation

enum ConfigurationCheckError: Error, LocalizedError {
    case coreRejected
    var errorDescription: String? { "网络核心未通过配置检查，临时任务和配置已清理" }
}

/// Only -t. No network snapshot, arbitrary path, job label or launch arguments
/// are accepted in this record. A running VPN needs a different schema.
struct CoreCheckRecord: Codable, Equatable {
    enum Stage: String, Codable { case registering, registered, starting, started, exited, removed }
    let origin: ServiceProcessOrigin
    let coreSHA256: String
    var stage: Stage = .registering
    var pid: pid_t?
    var exitCode: Int32?

    func validate(_ object: [String: Any]) throws {
        var keys: Set<String> = ["origin", "coreSHA256", "stage"]
        if pid != nil { keys.insert("pid") }
        if exitCode != nil { keys.insert("exitCode") }
        guard Set(object.keys) == keys, let source = object["origin"] as? [String: Any],
              Set(source.keys) == ["bootID", "groupID", "ownerUID"], origin.groupID > 1,
              coreSHA256.count == 64,
              coreSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SessionStoreError.invalidRecord
        }
        if let pid, pid <= 1 { throw SessionStoreError.invalidRecord }
        if let exitCode, !(-128...255).contains(exitCode) { throw SessionStoreError.invalidRecord }
        switch stage {
        case .registering, .registered, .starting:
            guard pid == nil, exitCode == nil else { throw SessionStoreError.invalidRecord }
        case .started:
            guard pid != nil, exitCode == nil else { throw SessionStoreError.invalidRecord }
        case .exited:
            guard exitCode != nil else { throw SessionStoreError.invalidRecord }
        case .removed: break
        }
    }
}
