import Foundation

public enum ApplicationLocation {
    public static func requiresInstallation(at bundle: URL) throws -> Bool {
        let url = bundle.standardizedFileURL.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        guard let readOnly = values.volumeIsReadOnly else { throw CocoaError(.fileReadUnknown) }
        return requiresInstallation(path: url, readOnly: readOnly)
    }

    static func requiresInstallation(path: URL, readOnly: Bool) -> Bool {
        if readOnly { return true }
        let parts = path.pathComponents
        return parts.indices.contains { index in
            parts[index] == "AppTranslocation" && index + 2 < parts.count &&
                UUID(uuidString: parts[index + 1]) != nil && parts[index + 2] == "d"
        }
    }
}
