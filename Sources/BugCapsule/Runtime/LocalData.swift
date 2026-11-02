import Foundation

/// What `BugCapsule.clearLocalData()` and withdrawn consent delete under
/// the storage root: saved and queued capsules, queued monitoring
/// envelopes, crash journals, native crash reports, the crash bridge's
/// pending events, release-health state and the monitoring install id.
///
/// Kept, because they hold no app or user data and the SDK must keep
/// honouring them offline:
/// * `emergency/`: the signed emergency policies (guards keep working
///   without a network) and the emergency installation id;
/// * `remote_config.json`: the server's kill switch and limits (dropping it
///   would let a killed app capture again until the next fetch).
///
/// Directories stay (a running outbox or the native crash writer writes
/// into them); only `journal/<pid>` directories go entirely.
enum LocalData {
    static let kept: Set<String> = ["emergency", "remote_config.json"]

    static func wipe(root: URL) {
        let items = (try? FileIO.fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in items where !kept.contains(item.lastPathComponent) {
            if item.lastPathComponent == "journal" {
                for dir in (try? FileIO.fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] {
                    FileIO.deleteQuietly(dir)
                }
            } else if isDirectory(item) {
                removeFiles(in: item)
            } else {
                FileIO.deleteQuietly(item)
            }
        }
    }

    /// Deletes every file below [dir], keeping the directories.
    private static func removeFiles(in dir: URL) {
        for item in (try? FileIO.fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            if isDirectory(item) { removeFiles(in: item) } else { FileIO.deleteQuietly(item) }
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}

/// The app's collection consent (`BugCapsule.setCollectionEnabled`),
/// persisted in the app's own `UserDefaults` so it holds from the first
/// line of the next launch. Unset: `BugCapsuleConfig.collectionEnabledByDefault`.
enum CollectionConsent {
    static let key = "BugCapsuleCollectionEnabled"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _defaults: UserDefaults?

    /// `.standard` unless replaced (tests).
    static var defaults: UserDefaults {
        get { lock.locked { _defaults ?? .standard } }
        set { lock.locked { _defaults = newValue } }
    }

    static var stored: Bool? { defaults.object(forKey: key) as? Bool }

    static func store(_ enabled: Bool) { defaults.set(enabled, forKey: key) }

    static func isEnabled(default value: Bool) -> Bool { stored ?? value }
}
