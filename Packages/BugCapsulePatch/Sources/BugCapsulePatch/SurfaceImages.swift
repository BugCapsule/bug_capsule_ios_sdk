#if os(iOS)
import Foundation

/// Check every node before rendering anything, including offscreen list children.
func surfaceImagesAvailable(_ root: [String: Any], available: Set<String>) -> Bool {
    var nodes = 0
    func visit(_ node: [String: Any], depth: Int) -> Bool {
        nodes += 1
        guard nodes <= 512, depth <= 16 else { return false }
        if node["type"] as? String == "image" {
            guard let asset = node["asset"] as? String, available.contains(asset),
                  node["label"] is String else { return false }
        }
        guard let children = node["children"] else { return true }
        guard let children = children as? [[String: Any]] else { return false }
        return children.allSatisfy { visit($0, depth: depth + 1) }
    }
    return visit(root, depth: 0)
}

#endif
