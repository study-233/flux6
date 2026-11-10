import Foundation
import FreeV6Desktop
import FreeV6System

extension FreeV6HostCoordinator {
    // StandardMessageCodec encodes signed 64-bit integers. Never wrap an
    // unsigned accounting total into a negative value at the channel boundary.
    private func count(_ value: UInt64) -> Int64 { Int64(clamping: value) }

    func trafficSnapshot() -> [String: Any] {
        let last = controls.currentTraffic == nil ? nil : controls.history.last
        var data: [String: Any] = [
            "version": 1, "cursor": cursor, "sessionId": network.ownedTarget?.sessionID.uuidString as Any? ?? NSNull(),
            "sessionRevision": network.ownedTarget.map { count($0.revision) } as Any? ?? NSNull(),
            "sampleSeq": sampleSeq, "sampleTime": last.map { ISO8601DateFormatter().string(from: $0.date) } as Any? ?? NSNull(),
            "uploadHistory": controls.history.map { Double($0.sample.up) },
            "downloadHistory": controls.history.map { Double($0.sample.down) },
            "uploadRate": last.map { Double($0.sample.up) } as Any? ?? NSNull(),
            "downloadRate": last.map { Double($0.sample.down) } as Any? ?? NSNull(),
            "startedAt": started.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
            "uptimeSeconds": started.map { max(0, Int(Date().timeIntervalSince($0))) } as Any? ?? NSNull(),
            "trafficError": controls.trafficError as Any? ?? NSNull(),
        ]
        if let report {
            data["usage"] = ["monthlyUpload": count(report.monthly.upload), "monthlyDownload": count(report.monthly.download),
                             "totalUpload": count(report.total.upload), "totalDownload": count(report.total.download)]
        } else { data["usage"] = NSNull() }
        return data
    }

    func makeSnapshot() -> [String: Any] {
        var data = trafficSnapshot()
        let currentGroups = groups
        let access = currentGroups.first { $0.group == .access }
        let connected = network.phase == .running
        let canChoose = settings.accepted && settings.stored != nil &&
            (modeSource == .savedDefault || (modeSource == .liveSession && controls.state != nil))
        let own = network.ownedTarget
        let capabilities: [String: Bool] = [
            "connect": settings.accepted && !settings.blockedForConnection && service == .ready && network.phase == .idle && settings.stored != nil,
            "disconnect": service == .ready && own != nil && (connected || network.phase == .recovering),
            "mode": canChoose, "node": canChoose && !currentGroups.isEmpty,
            "measure": connected && controls.state != nil && !controls.measuring && downloadTask == nil && access?.members.isEmpty == false,
            "download": connected && controls.state != nil && !controls.measuring && downloadTask == nil,
            "prepareService": !network.mayOwnSession && (service != .ready || network.phase == .idle),
            "checkConfiguration": canCheckConfiguration,
        ]
        let phase: String
        switch network.phase {
        case .unknown: phase = "unknown"; case .idle: phase = "idle"; case .connecting: phase = "connecting"
        case .running: phase = "running"; case .disconnecting: phase = "disconnecting"; case .recovering: phase = "recovering"
        case .occupied: phase = "occupied"
        }
        let status: String
        switch service {
        case .ready: status = "ready"; case .checking: status = "checking"; case .missing: status = "missing"
        case .managing: status = "managing"; case .needsRepair: status = "needsRepair"
        }
        let records = logs.records.suffix(3).reversed().map { row -> [String: Any] in
            ["id": row.id.uuidString, "time": ISO8601DateFormatter().string(from: row.date),
             "level": row.event.level.rawValue, "source": row.event.source.title, "message": row.event.rawValue]
        }
        let nodeGroups = currentGroups.map { group -> [String: Any] in
            let source: String
            switch group.source { case .session: source = "session"; case .configuration: source = "configuration"; case .previousSession: source = "previousSession" }
            var delay: [String: Any] = [:]
            for (name, result) in controls.latency[group.group] ?? [:] {
                switch result { case .measured(let ms): delay[name] = ms; case .timedOut: delay[name] = "timeout"; case .unavailable: delay[name] = "unavailable" }
            }
            return ["id": group.id.rawValue, "members": group.members, "automatic": group.automatic, "source": source,
                    "preferred": group.preferred as Any? ?? NSNull(), "current": group.selected as Any? ?? NSNull(), "latencies": delay]
        }
        let stored = settings.stored?.settings.mode.rawValue
        let liveMode = connected ? controls.state?.mode.rawValue : nil
        data.merge([
            "environment": isolated ? "isolated" : "live", "phase": phase, "phaseLabel": network.phase.title, "service": status,
            "mode": (liveMode ?? stored) as Any? ?? NSNull(), "liveMode": liveMode as Any? ?? NSNull(),
            "savedMode": stored as Any? ?? NSNull(), "group": "access", "nodes": access?.members ?? [], "groups": nodeGroups,
            "currentNode": access?.selected as Any? ?? NSNull(), "preferredNode": access?.preferred as Any? ?? NSNull(),
            "latencies": nodeGroups.first(where: { $0["id"] as? String == "access" })?["latencies"] ?? [:],
            "controlToken": controls.state?.token.uuidString as Any? ?? NSNull(), "measuring": controls.measuring,
            "measuringMember": controls.measuringMember as Any? ?? NSNull(),
            "revision": settings.stored.map { count($0.revision) } as Any? ?? NSNull(), "capabilities": capabilities,
            "logs": records, "profileName": settings.stored?.cloud?.enabled == true ? "备用配置" : "校园 IPv6",
            "error": (error ?? controls.error ?? network.statusError ?? network.error) as Any? ?? NSNull(),
            "settings": settings.snapshot(), "shouldStartHidden": settings.startup.shouldStartHidden,
            "automaticStatus": settings.startup.automaticStatus as Any? ?? NSNull(),
            "configurationCheckMessage": (configurationCheckRevision == settings.stored?.revision ? configurationCheckMessage : nil) as Any? ?? NSNull(),
            "checkingConfiguration": checkingConfiguration,
            "download": downloadSnapshot,
            "setup": ["active": setupTask != nil, "step": setupStep, "status": setupStatus, "error": setupError ?? ""],
        ] as [String: Any]) { _, new in new }
        return data
    }
}
