import AppKit

/// The app's icon glyph: Lucide "rotate-cw", used as-is (ISC License, see THIRD_PARTY_NOTICES.md). Shown in the menu bar and the banner.
enum AppGlyph {
    /// Lucide `rotate-cw`, paths unmodified; stroke colour set to black for template use.
    static let svg = ##"""
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#000000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8" /><path d="M21 3v5h-5" /></svg>
    """##

    /// A template image (adapts to light/dark menu bars) of the given point size.
    static func image(size: CGFloat) -> NSImage? {
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        image.accessibilityDescription = "Just Continue"
        return image
    }

    /// The menu-bar icon. With `badge`, a small dot at the bottom right, just outside the arc,
    /// shows that at least one session is set to continue or the Mac is kept awake. Both variants have the same size, so the
    /// icon doesn't shift in the menu bar when the dot appears.
    static func menuBarImage(badge: Bool) -> NSImage? {
        guard let glyph = image(size: 15) else { return nil }
        let image = NSImage(size: NSSize(width: 19, height: 16), flipped: false) { _ in
            glyph.draw(in: NSRect(x: 0, y: 0.5, width: 15, height: 15))
            if badge {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 13.5, y: 0.5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = badge ? "Just Continue, on" : "Just Continue"
        return image
    }

    /// Shown under Settings › Troubleshooting › Acknowledgements.
    static let acknowledgements = """
    Lucide — "rotate-cw" icon (https://lucide.dev)

    ISC License

    Copyright (c) 2026 Lucide Icons and Contributors

    Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

    THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
    """
}
