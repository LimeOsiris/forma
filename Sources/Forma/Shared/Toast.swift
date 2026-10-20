import AppKit
import Quartz
import SwiftUI
@preconcurrency import UserNotifications

/// A small, self-dismissing message near the cursor for things that don't deserve a dialog.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String, symbol: String = "info.circle", near point: NSPoint = NSEvent.mouseLocation, duration: Double = 3) {
        hideTask?.cancel()
        panel?.orderOut(nil)
        let view = NSHostingView(rootView: ToastView(message: message, symbol: symbol))
        let size = view.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = WheelPlacement.frame(size: size, centeredAt: NSPoint(x: point.x, y: point.y - 40), in: screen.visibleFrame)
        let p = WheelPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = view
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        panel = p
        NSAccessibility.post(element: p, notification: .announcementRequested, userInfo: [.announcement: message])
        hideTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { MainActor.assumeIsolated { p.orderOut(nil) } })
        }
    }
}

private struct ToastView: View {
    let message: String
    let symbol: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .padding(16)
    }
}

/// Local notifications for conversions that finish after the wheel was dismissed.
/// Authorization is requested lazily, the first time one is actually needed.
@MainActor
enum Notifier {
    final class Delegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            let paths = response.notification.request.content.userInfo["reveal"] as? [String] ?? []
            let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty { await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting(urls) } }
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner]
        }
    }

    private static let delegate = Delegate()

    static func post(title: String, body: String, reveal: [URL]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["reveal": reveal.prefix(50).map(\.path)]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }
}

/// Quick Look preview of the selected files via QLPreviewPanel.
@MainActor
final class QuickLookController: NSResponder, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        self.urls = urls
        NSApp.activate(ignoringOtherApps: true)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}
