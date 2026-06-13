import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class DebugHUDStore {
    static let shared = DebugHUDStore()

    var isVisible = false
    var events: [String] = []

    private let maxEvents = 10

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if !visible {
            events.removeAll(keepingCapacity: true)
        }
    }

    func reset() {
        events.removeAll(keepingCapacity: true)
    }

    func append(_ line: String) {
        guard isVisible else { return }

        events.append(line)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }
}

@MainActor
final class DebugHUDWindowController {
    static let shared = DebugHUDWindowController()

    private var panel: NSPanel?

    private init() {}

    func setVisible(_ visible: Bool) {
        DebugHUDStore.shared.setVisible(visible)

        guard visible else {
            panel?.orderOut(nil)
            return
        }

        let panel = panel ?? makePanel()
        position(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 520, height: 180)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: DebugHUDView(store: DebugHUDStore.shared))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }

        let margin: CGFloat = 18
        let visibleFrame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.maxX - size.width - margin,
            y: visibleFrame.maxY - size.height - margin
        )
        panel.setFrameOrigin(origin)
    }
}

struct DebugHUDView: View {
    @Bindable var store: DebugHUDStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.caption.weight(.semibold))
                Text("Debug events")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(DebugFileLog.logPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Divider()
                .opacity(0.35)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(store.events.enumerated()), id: \.offset) { _, event in
                    Text(event)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(width: 520, height: 180, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        )
    }
}