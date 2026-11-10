import Foundation

/// The ledger stores two UInt64 counters. Their sum can be larger than either counter.
public struct DashboardTrafficUsage {
    public let total: Decimal
    public let downloadFraction: Double

    public init(upload: UInt64, download: UInt64) {
        total = Decimal(upload) + Decimal(download)
        let bytes = Double(upload) + Double(download)
        downloadFraction = bytes == 0 ? 0 : Double(download) / bytes
    }
}
