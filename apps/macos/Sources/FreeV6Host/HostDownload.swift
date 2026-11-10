import Foundation
import FreeV6System

extension FreeV6HostCoordinator {
    func startDownloads(target: SessionControlTarget, group: SessionNodeGroup, members: [String]) {
        guard downloadTask == nil, !members.isEmpty else { return }
        if downloadTarget != target { downloadResults = [:] }
        let queries = members.map { SessionControlRequest(target, .download, group: group, member: $0) }
        downloadTarget = target; downloadQuery = queries[0]; downloadStarted = Date()
        downloadTotal = members.count; downloadCompleted = 0; downloadCancelling = false
        downloadTask = Task { @MainActor in
            defer {
                downloadTask = nil; downloadQuery = nil; downloadStarted = nil
                downloadCancelling = false; publish("state")
            }
            // One queue per host; each request still uses the service's bounded
            // single-node path. Failures advance the queue; cancellation and a
            // changed session stop it before any further node is requested.
            for query in queries {
                guard !Task.isCancelled, network.runningTarget == target else { break }
                let key = group.rawValue, node = query.member!
                downloadQuery = query
                downloadResults[key, default: [:]][node] = ["status": "running"]
                publish("state")
                do {
                    let reply = try await backend.control(query)
                    try Task.checkCancellation()
                    guard network.runningTarget == target, let result = reply.download else {
                        throw HostFailure("staleSession", "网络会话已变化，请重新测速。")
                    }
                    downloadResults[key, default: [:]][node] = ["status": "complete", "bytes": result.bytes,
                        "seconds": result.seconds, "bytesPerSecond": result.bytesPerSecond,
                        "time": ISO8601DateFormatter().string(from: result.measuredAt)]
                } catch {
                    downloadResults[key, default: [:]][node] = ["status": Task.isCancelled ? "cancelled" : "failed",
                        "message": Task.isCancelled ? "已取消" : "下载测试未完成，请检查节点后重试。"]
                    if Task.isCancelled || network.runningTarget != target { break }
                }
                downloadCompleted += 1
                publish("state")
            }
        }
    }

    func cancelDownload() async {
        guard let query = downloadQuery, let task = downloadTask else { return }
        downloadCancelling = true; publish("state")
        task.cancel()
        _ = try? await backend.control(SessionControlRequest(query.target, .cancelDownload, token: query.requestID))
        await task.value
    }

    var downloadSnapshot: [String: Any] {
        ["active": downloadTask != nil, "node": downloadQuery?.member ?? "", "group": downloadQuery?.group?.rawValue ?? "",
         "startedAt": downloadStarted.map { ISO8601DateFormatter().string(from: $0) } ?? "",
         "total": downloadTotal, "completed": downloadCompleted, "cancelling": downloadCancelling,
         "results": downloadTarget == network.runningTarget ? downloadResults : [:]]
    }
}
