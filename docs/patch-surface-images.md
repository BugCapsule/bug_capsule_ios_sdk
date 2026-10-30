# Images in patch surfaces

Register image IDs in the surface contract's `assets` list and include `image`
in its components. Pass app-owned SwiftUI images keyed by those registered IDs:

```swift
PatchSurfaceView(
    patch: patch,
    id: "checkout.summary",
    actions: ["checkout.pay": pay],
    images: ["brand.logo": Image("BrandLogo")]
) {
    BundledCheckoutSummary()
}
```

A signed surface image node such as
`{"type":"image","asset":"brand.logo","label":"Brand logo"}` renders the
supplied image and exposes its required `label` as its accessibility label.

Image allocation/loading stays app-owned. No patch asset bytes are decoded and
no URLs are loaded by the renderer. An image map entry does not authorize an
unregistered ID; engine contract validation still applies. Missing any image,
including one nested in a scrollable list, chooses the entire bundled surface.
The default empty map preserves existing call sites and surfaces without images.
