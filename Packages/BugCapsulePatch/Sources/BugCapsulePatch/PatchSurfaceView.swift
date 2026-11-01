#if os(iOS)
import SwiftUI

/// Renders the patched layout of a registered surface with shipped views, or
/// `bundled` when this generation has none. Actions run the app's handlers.
/// `images` maps registered asset IDs to app-supplied images. No patch bytes or
/// URLs are decoded. A missing referenced image falls back to the whole bundled
/// surface, including its actions.
public struct PatchSurfaceView<Bundled: View>: View {
    private let document: [String: Any]?
    private let images: [String: Image]
    private let actions: [String: () -> Void]
    private let onTextChanged: (String, String, String) -> Void
    private let bundled: Bundled

    public init(
        patch: BugCapsulePatch,
        id: String,
        actions: [String: () -> Void],
        images: [String: Image] = [:],
        onTextChanged: @escaping (String, String, String) -> Void = { _, _, _ in },
        @ViewBuilder bundled: () -> Bundled
    ) {
        document = patch.surface(id)?["root"] as? [String: Any]
        self.images = images
        self.actions = actions
        self.onTextChanged = onTextChanged
        self.bundled = bundled()
    }

    public var body: some View {
        if let document, surfaceImagesAvailable(document, available: Set(images.keys)) {
            PatchNode(node: document, actions: actions, images: images, onTextChanged: onTextChanged)
        } else {
            bundled
        }
    }
}

private struct PatchNode: View {
    let node: [String: Any]
    let actions: [String: () -> Void]
    let images: [String: Image]
    let onTextChanged: (String, String, String) -> Void

    private var children: [[String: Any]] { node["children"] as? [[String: Any]] ?? [] }
    private var spacing: CGFloat { CGFloat(node["spacing"] as? Int ?? 0) }
    private var string: (String) -> String { { node[$0] as? String ?? "" } }

    var body: AnyView {
        switch string("type") {
        case "text":
            return AnyView(Text(string("text")).font(font))
        case "image":
            // The complete tree is checked before rendering; images are a value snapshot.
            return AnyView(images[string("asset")]!.accessibilityLabel(string("label")))
        case "spacer":
            return AnyView(Color.clear.frame(width: CGFloat(node["size"] as? Int ?? 0), height: CGFloat(node["size"] as? Int ?? 0)))
        case "button":
            return AnyView(Button(string("label")) { actions[string("action")]?() }.buttonStyle(.borderedProminent))
        case "text_field":
            return AnyView(PatchField(label: string("label")) { onTextChanged(string("action"), string("id"), $0) })
        case "row":
            return AnyView(HStack(spacing: spacing) { nodes })
        case "list":
            return AnyView(ScrollView { VStack(alignment: .leading, spacing: spacing) { nodes } })
        default:
            return AnyView(VStack(alignment: .leading, spacing: spacing) { nodes })
        }
    }

    private var nodes: some View {
        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
            PatchNode(node: child, actions: actions, images: images, onTextChanged: onTextChanged)
        }
    }

    private var font: Font {
        switch string("style") {
        case "title": return .title2
        case "caption": return .caption
        default: return .body
        }
    }
}

private struct PatchField: View {
    let label: String
    let onChange: (String) -> Void
    @State private var value = ""

    var body: some View {
        TextField(label, text: Binding(get: { value }, set: { value = $0; onChange($0) }))
            .textFieldStyle(.roundedBorder)
    }
}

#endif
