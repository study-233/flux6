import Darwin
import Foundation
import dnssd

/// Query the system resolver after activation. Each name is fresh so both a
/// cached answer and an earlier negative response cannot confirm this attempt.
enum SystemResolverCheck {
    private final class Answer { var received = false; var valid = false }

    static func verify(sessionID: UUID, devices: [String]) throws {
        var scopes: Set<UInt32> = [0] // default resolver and each affected link
        for device in devices {
            let index = if_nametoindex(device)
            guard index != 0 else { throw SessionDNSError.changed }
            scopes.insert(index)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        for scope in scopes.sorted() {
            while true {
                let now = ProcessInfo.processInfo.systemUptime
                guard now < deadline else { throw SessionDNSError.applyFailed }
                let name = DNSResolverPolicy.freshName(sessionID) + "."
                if resolves(name, scope: scope, deadline: min(deadline, now + 1.0)) { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    private static func resolves(_ name: String, scope: UInt32, deadline: TimeInterval) -> Bool {
        var query: DNSServiceRef?
        let answer = Answer()
        let code = DNSServiceQueryRecord(&query, 0, scope, name, UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
            { _, flags, _, error, _, type, rrclass, length, data, _, context in
                guard let context else { return }
                let answer = Unmanaged<Answer>.fromOpaque(context).takeUnretainedValue()
                answer.received = true
                guard error == kDNSServiceErr_NoError, flags & UInt32(kDNSServiceFlagsAdd) != 0,
                      type == kDNSServiceType_A, rrclass == kDNSServiceClass_IN, length == 4, let data else { return }
                let bytes = UnsafeRawBufferPointer(start: data, count: 4)
                answer.valid = answer.valid || bytes.elementsEqual([192, 0, 2, 1])
            }, Unmanaged.passUnretained(answer).toOpaque())
        guard code == kDNSServiceErr_NoError, let query else { return false }
        defer { DNSServiceRefDeallocate(query) }
        let fd = DNSServiceRefSockFD(query)
        guard fd >= 0 else { return false }
        while !answer.received {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let count = poll(&poller, 1, Int32(ceil(remaining * 1000)))
            if count < 0, errno == EINTR { continue }
            guard count > 0, poller.revents & Int16(POLLIN) != 0,
                  DNSServiceProcessResult(query) == kDNSServiceErr_NoError else { return false }
        }
        return answer.valid
    }
}
