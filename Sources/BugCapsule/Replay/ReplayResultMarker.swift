import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// Shows the replay report to the UI test: a 2×2 pt, non-interactive
/// window above alerts holding an accessibility element
/// (`bugcapsule.replay.result`) whose value is the report JSON. The
/// `BugCapsuleXCTest` helper waits for it and prints the
/// `BUGCAPSULE_RESULT::` line into the xcodebuild output. Exists only in
/// replay (DEBUG builds launched by the UI test).
enum ReplayResultMarker {
    static func publish(_ json: String) {
        #if canImport(UIKit)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { show(json) }
            }
        #endif
    }

    #if canImport(UIKit)
        @MainActor private static var window: UIWindow?

        @MainActor
        private static func show(_ json: String) {
            guard
                let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive })
                    ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
            else { return }
            let w = window ?? UIWindow(windowScene: scene)
            w.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
            w.windowLevel = .alert + 100
            w.isUserInteractionEnabled = false
            let vc = UIViewController()
            let marker = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
            marker.backgroundColor = UIColor(white: 0, alpha: 0.02)
            marker.isAccessibilityElement = true
            marker.accessibilityIdentifier = ReplayProtocol.resultAccessibilityId
            marker.accessibilityLabel = "BugCapsule replay result"
            marker.accessibilityValue = json
            vc.view = marker
            w.rootViewController = vc
            w.isHidden = false
            window = w
        }
    #endif
}
