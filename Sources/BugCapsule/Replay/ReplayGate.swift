import Foundation

/// Decides whether this launch is a replay (runtimes-v1 §10, iOS row).
///
/// Replay arms only when all of these hold:
/// * the SDK was compiled with `DEBUG` (the code path does not exist in
///   release builds: there is no URL scheme, deep link, push or file that
///   can turn it on in production);
/// * the process was launched with the `-BugCapsuleReplay` argument, which
///   `BugCapsuleXCTest` adds when the UI test launches the app;
/// * `BUGCAPSULE_REPLAY_URL` is in the launch environment
///   (`XCUIApplication.launchEnvironment`) and is an http(s) loopback or LAN URL.
enum ReplayGate {
    static func replayURL(
        configURL: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String? {
        #if DEBUG
            if let configURL, isAcceptable(configURL) { return configURL }
            guard arguments.contains(ReplayProtocol.launchArgument) else { return nil }
            guard let url = environment[ReplayProtocol.envURL], isAcceptable(url) else { return nil }
            return url
        #else
            return nil
        #endif
    }

    /// True when this build can enter replay at all.
    static var compiledIn: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }

    static func isAcceptable(_ url: String) -> Bool {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
            u.host != nil
        else { return false }
        return true
    }
}
