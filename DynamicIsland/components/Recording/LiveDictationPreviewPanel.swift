import AppKit
import SwiftUI

@MainActor
final class LiveDictationPreviewPanel {
    static let shared = LiveDictationPreviewPanel()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 190),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: LiveDictationPreview())
            self.panel = panel
        }
        guard let panel,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - 240, y: visible.minY + 80))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct LiveDictationPreview: View {
    @ObservedObject private var manager = DictationManager.shared

    private var status: String {
        if manager.isRefiningLive { return "Light correction…" }
        if manager.isTranscribing { return "Finishing…" }
        return "Recording…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: manager.isRecording ? "mic.fill" : "text.badge.checkmark")
                    .foregroundStyle(.orange)
                Text("AI Cleanup Preview").fontWeight(.semibold)
                Spacer()
                Text(status).foregroundStyle(.secondary)
            }
            .font(.caption)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading) {
                        Text(manager.liveTranscript.isEmpty ? "Your words will appear here." : manager.liveTranscript)
                            .foregroundStyle(manager.liveTranscript.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: manager.liveTranscript) { _, _ in
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            Text(manager.liveNotice ?? "Periodic preview · Text is inserted when recording ends.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(16)
        .frame(width: 480, height: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }
}
