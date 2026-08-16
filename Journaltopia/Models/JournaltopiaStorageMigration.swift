import Foundation

enum JournaltopiaStorageMigration {
    private static let currentPrefix = "Journaltopia"
    private static let legacyPrefix = "Story" + "topia"

    static func migrateLegacyIdentifiersIfNeeded() {
        migrateUserDefaults()
        migrateDocumentDirectory(named: "\(legacyPrefix)Accounts", to: "\(currentPrefix)Accounts")
        removeCacheDirectory(named: "\(legacyPrefix)SupabaseImageCache")
        removeCacheDirectory(named: legacyPrefix)
    }

    private static func migrateUserDefaults() {
        let defaults = UserDefaults.standard
        let keys = Array(defaults.dictionaryRepresentation().keys)

        for legacyKey in keys where legacyKey.hasPrefix(legacyPrefix) {
            let currentKey = currentPrefix + String(legacyKey.dropFirst(legacyPrefix.count))

            if defaults.object(forKey: currentKey) == nil,
               let value = defaults.object(forKey: legacyKey) {
                defaults.set(value, forKey: currentKey)
            }

            defaults.removeObject(forKey: legacyKey)
        }
    }

    private static func migrateDocumentDirectory(named legacyName: String, to currentName: String) {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let legacyURL = documentsURL.appendingPathComponent(legacyName, isDirectory: true)
        let currentURL = documentsURL.appendingPathComponent(currentName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            return
        }

        do {
            try copyDirectoryContents(from: legacyURL, to: currentURL)
            try FileManager.default.removeItem(at: legacyURL)
        } catch {
            print("[Journaltopia] Local storage migration skipped: \(error.localizedDescription)")
        }
    }

    private static func copyDirectoryContents(from sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let contents = try FileManager.default.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for sourceChildURL in contents {
            let destinationChildURL = destinationURL.appendingPathComponent(sourceChildURL.lastPathComponent)
            let resourceValues = try sourceChildURL.resourceValues(forKeys: [.isDirectoryKey])

            if resourceValues.isDirectory == true {
                try copyDirectoryContents(from: sourceChildURL, to: destinationChildURL)
            } else if !FileManager.default.fileExists(atPath: destinationChildURL.path) {
                try FileManager.default.copyItem(at: sourceChildURL, to: destinationChildURL)
            }
        }
    }

    private static func removeCacheDirectory(named name: String) {
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }

        let directoryURL = cachesURL.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: directoryURL)
        } catch {
            print("[Journaltopia] Legacy cache cleanup skipped: \(error.localizedDescription)")
        }
    }
}
