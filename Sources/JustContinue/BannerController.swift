import AppKit
import SwiftUI

/// In-app banner for when system notifications are off. A non-activating panel
/// in the top-right corner: it never takes focus from what the user is doing.
@MainActor
final class BannerController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// What's showing (for the debug scenario test).
    private(set) var currentTitle: String?
    private(set) var currentHasAction = false
    var isVisible: Bool { panel != nil }

    struct Action {
        var title: String
        var run: () -> Void
    }

    /// Shows a banner, replacing any current one. Banners with an action, or `persistent` ones,
    /// stay until closed; others hide after 8 s.
    func show(title: String, body: String, action: Action? = nil, persistent: Bool = false) {
        hide()
        currentTitle = title
        currentHasAction = action != nil
        let view = BannerView(title: title, message: body, action: action.map { a in
            Action(title: a.title) { [weak self] in a.run(); self?.hide() }
        }, close: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.invalidateShadow()
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()  // shown without activating the app
        self.panel = panel

        if action == nil, !persistent {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { self?.hide() }
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
        currentTitle = nil
        currentHasAction = false
    }
}

/// Notification-style banner: app icon, title and text, then standard push buttons.
/// No border; the panel's shadow separates it from what's behind.
private struct BannerView: View {
    let title: String
    let message: String
    let action: BannerController.Action?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AppIconImage()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            // Standard macOS push buttons, right-aligned like an alert; the action is the primary one.
            HStack(spacing: 8) {
                Spacer()
                Button("Close", action: close)
                if let action {
                    Button(action.title, action: action.run)
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            .controlSize(.regular)
        }
        .padding(14)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The macOS default (blue) push button. Drawn explicitly because AppKit shows default buttons as
/// inactive in windows without focus, and the banner deliberately never takes focus.
private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1))
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            )
    }
}

/// The app icon once the bundle has one; a neutral stand-in until then.
private struct AppIconImage: View {
    var body: some View {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil || Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") != nil {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.12))
                .frame(width: 38, height: 38)
                .overlay(Image(nsImage: AppGlyph.image(size: 20) ?? NSImage()).renderingMode(.template).foregroundStyle(.primary))
        }
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
