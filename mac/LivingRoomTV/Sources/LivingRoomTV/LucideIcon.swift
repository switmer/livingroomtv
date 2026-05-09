import SwiftUI
import AppKit

/// Renders a Lucide icon from the app's resource bundle. Loads the PNG
/// explicitly via Bundle.module.url(forResource:) so we can mark the
/// underlying NSImage as a template — without that flag, dark Lucide
/// strokes stay black-on-black in dark mode instead of being tinted by
/// `foregroundStyle`.
struct LucideIcon: View {
    let name: String
    var size: CGFloat = 16

    var body: some View {
        if let image = Self.cache[name] ?? Self.load(name) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    // MainActor-isolated cache — SwiftUI view bodies all run on the main
    // actor, so this matches the only real access site and prevents any
    // future background caller from racing on the dict.
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else {
            return nil
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
