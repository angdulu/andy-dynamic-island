/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class LockScreenWidgetPreviewManager: ObservableObject {
    static let shared = LockScreenWidgetPreviewManager()

    @Published private(set) var isPreviewVisible = false

    private var cancellables = Set<AnyCancellable>()
    private var startedDemoTimer = false
    private var previewWindow: NSWindow?
    private var previewWindowDelegate: PreviewWindowDelegate?
    private var previewHostingView: NSHostingView<LockScreenPreviewScene>?
    private var cachedFocusState: FocusPreviewState?

    private init() {
        observeDefaults()
    }

    func togglePreview() {
        if isPreviewVisible {
            hidePreview()
        } else {
            showPreview()
        }
    }

    func showPreview() {
        guard !isPreviewVisible else { return }
        isPreviewVisible = true
        ensurePreviewWindow()
        applyPreviewState()
        renderPreview()
    }

    func hidePreview() {
        guard isPreviewVisible else { return }
        isPreviewVisible = false
        hideAllWidgets()
        restorePreviewState()
        closePreviewWindow()
    }

    private func renderPreview() {
        guard isPreviewVisible else { return }

        ensurePreviewWindow()

        if Defaults[.enableLockScreenTimerWidget] {
            ensureDemoTimerIfNeeded()
        } else {
            stopDemoTimerIfNeeded()
        }

        updatePreviewContent()
    }

    private func hideAllWidgets() {
        stopDemoTimerIfNeeded()
    }

    private func ensureDemoTimerIfNeeded() {
        let timerManager = TimerManager.shared
        guard !timerManager.isTimerActive else { return }
        timerManager.startDemoTimer(duration: 1783)
        startedDemoTimer = true
    }

    private func stopDemoTimerIfNeeded() {
        guard startedDemoTimer else { return }
        TimerManager.shared.forceStopTimer()
        startedDemoTimer = false
    }

    private func observeDefaults() {
        observeKey(.enableLockScreenMediaWidget)
        observeKey(.enableLockScreenTimerWidget)
        observeKey(.lockScreenReminderChipStyle)
    }

    private func observeKey<T: Defaults.Serializable>(_ key: Defaults.Key<T>) {
        Defaults.publisher(key, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.renderPreview()
            }
            .store(in: &cancellables)
    }

    private func ensurePreviewWindow() {
        guard let screen = NSScreen.main else { return }

        if let window = previewWindow {
            window.makeKeyAndOrderFront(nil)
            updatePreviewContent()
            return
        }

        let frame = screen.frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Lock Screen Preview"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.center()

        let scene = LockScreenPreviewScene(
            screenSize: screen.frame.size,
            showsTimer: Defaults[.enableLockScreenTimerWidget],
            showsMediaPanel: Defaults[.enableLockScreenMediaWidget]
        )
        let hosting = NSHostingView(rootView: scene)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        previewHostingView = hosting
        window.contentView = hosting

        let delegate = PreviewWindowDelegate { [weak self] in
            self?.hidePreview()
        }
        previewWindowDelegate = delegate
        window.delegate = delegate

        previewWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func updatePreviewContent() {
        guard let screen = NSScreen.main else { return }
        let scene = LockScreenPreviewScene(
            screenSize: screen.frame.size,
            showsTimer: Defaults[.enableLockScreenTimerWidget],
            showsMediaPanel: Defaults[.enableLockScreenMediaWidget]
        )

        if let hosting = previewHostingView {
            hosting.rootView = scene
        } else if let window = previewWindow {
            let hosting = NSHostingView(rootView: scene)
            hosting.frame = NSRect(origin: .zero, size: window.frame.size)
            hosting.autoresizingMask = [.width, .height]
            previewHostingView = hosting
            window.contentView = hosting
        }
    }

    private func closePreviewWindow() {
        previewWindow?.orderOut(nil)
    }

    private func applyPreviewState() {
        applyFocusPreviewState()
        applyCalendarPreviewEvents()
    }

    private func restorePreviewState() {
        restoreFocusPreviewState()
        CalendarManager.shared.setLockScreenPreviewEvents(nil)
    }

    private func applyFocusPreviewState() {
        let manager = DoNotDisturbManager.shared
        if cachedFocusState == nil {
            cachedFocusState = FocusPreviewState(
                isActive: manager.isDoNotDisturbActive,
                name: manager.currentFocusModeName,
                identifier: manager.currentFocusModeIdentifier
            )
        }
        manager.isDoNotDisturbActive = true
        manager.currentFocusModeName = "Do Not Disturb"
        manager.currentFocusModeIdentifier = "com.apple.donotdisturb"
    }

    private func restoreFocusPreviewState() {
        guard let cachedFocusState else { return }
        let manager = DoNotDisturbManager.shared
        manager.isDoNotDisturbActive = cachedFocusState.isActive
        manager.currentFocusModeName = cachedFocusState.name
        manager.currentFocusModeIdentifier = cachedFocusState.identifier
        self.cachedFocusState = nil
    }

    private func applyCalendarPreviewEvents() {
        let now = Date()
        let reminderCalendar = CalendarModel(
            accountName: "Preview",
            id: "preview.reminders",
            title: "Reminders",
            color: .systemBlue,
            isSubscribed: false,
            isReminder: true
        )
        let reminderEvent = EventModel(
            id: "preview.reminder.pay-rent",
            start: now.addingTimeInterval(12 * 60),
            end: now.addingTimeInterval(42 * 60),
            title: "Pay rent",
            location: nil,
            notes: nil,
            url: nil,
            isAllDay: false,
            type: .reminder(completed: false),
            calendar: reminderCalendar,
            participants: [],
            timeZone: TimeZone.current,
            hasRecurrenceRules: false,
            priority: .high,
            conferenceURL: nil
        )

        let eventCalendar = CalendarModel(
            accountName: "Preview",
            id: "preview.calendar",
            title: "Calendar",
            color: .systemOrange,
            isSubscribed: false,
            isReminder: false
        )
        let event = EventModel(
            id: "preview.event.standup",
            start: now.addingTimeInterval(60 * 60),
            end: now.addingTimeInterval(90 * 60),
            title: "Design Review",
            location: "Studio",
            notes: nil,
            url: nil,
            isAllDay: false,
            type: .event(.accepted),
            calendar: eventCalendar,
            participants: [],
            timeZone: TimeZone.current,
            hasRecurrenceRules: false,
            priority: nil,
            conferenceURL: nil
        )

        CalendarManager.shared.setLockScreenPreviewEvents([reminderEvent, event])
    }
}

private struct FocusPreviewState {
    let isActive: Bool
    let name: String
    let identifier: String
}

private final class PreviewWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct LockScreenPreviewScene: View {
    let screenSize: CGSize
    let showsTimer: Bool
    let showsMediaPanel: Bool

    @State private var musicSize: CGSize = .zero
    @StateObject private var panelAnimator = LockScreenPanelAnimator()

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / screenSize.width, proxy.size.height / screenSize.height)
            let contentSize = CGSize(width: screenSize.width * scale, height: screenSize.height * scale)
            let origin = CGPoint(
                x: (proxy.size.width - contentSize.width) / 2,
                y: (proxy.size.height - contentSize.height) / 2
            )

            ZStack(alignment: .topLeading) {
                WallpaperView()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                ZStack(alignment: .topLeading) {
                    if showsMediaPanel {
                        LockScreenMusicPanel(animator: panelAnimator)
                            .fixedSize()
                            .background(PreviewSizeReader(size: $musicSize))
                            .position(centerPoint(for: swiftUIFrame(for: mediaFrame)))
                            .onAppear {
                                panelAnimator.isPresented = true
                            }
                    }

                    if showsTimer {
                        LockScreenTimerWidget()
                            .frame(width: timerFrame.width, height: timerFrame.height)
                            .position(centerPoint(for: swiftUIFrame(for: timerFrame)))
                    }
                }
                .frame(width: screenSize.width, height: screenSize.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: origin.x, y: origin.y)
            }
        }
        .ignoresSafeArea()
    }

    private var mediaFrame: CGRect {
        let size = musicSize == .zero ? LockScreenMusicPanel.collapsedSize : musicSize
        let screenFrame = CGRect(origin: .zero, size: screenSize)
        let originX = screenFrame.midX - (size.width / 2)
        let baseOriginY = screenFrame.origin.y + (screenFrame.height / 2) - size.height - 32
        let defaultLowering: CGFloat = -28
        let userOffset = CGFloat(Defaults[.lockScreenMusicVerticalOffset])
        let clampedOffset = min(max(userOffset, -160), 160)
        var originY = baseOriginY + defaultLowering + clampedOffset

        if showsTimer {
            let maxAllowedTop = timerFrame.minY - 12
            let maxOriginY = maxAllowedTop - size.height
            originY = min(originY, maxOriginY)
        }

        return CGRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    private var timerFrame: CGRect {
        let size = LockScreenTimerWidget.preferredSize
        let screenFrame = CGRect(origin: .zero, size: screenSize)
        let originX = screenFrame.midX - (size.width / 2)
        let defaultLowering: CGFloat = -18
        let baseY = screenFrame.midY + 24 + defaultLowering

        let offset = CGFloat(min(max(Defaults[.lockScreenTimerVerticalOffset], -160), 160))
        var originY = baseY + offset

        let topLimit = screenFrame.maxY - size.height - 72
        originY = min(originY, topLimit)

        let minY = screenFrame.minY + 100
        originY = max(originY, minY)

        return CGRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    private func swiftUIFrame(for appKitFrame: CGRect) -> CGRect {
        let originY = screenSize.height - appKitFrame.maxY
        return CGRect(x: appKitFrame.origin.x, y: originY, width: appKitFrame.width, height: appKitFrame.height)
    }

    private func centerPoint(for frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }
}

private struct PreviewSizeReader: View {
    @Binding var size: CGSize

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { size = proxy.size }
                .onChange(of: proxy.size) { _, newSize in
                    size = newSize
                }
        }
    }
}

struct WallpaperView: View {
    @State private var wallpaperImage: NSImage?

    var body: some View {
        ZStack {
            if let image = wallpaperImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
                Text("Loading...")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: loadWallpaper)
    }

    func loadWallpaper() {
        if let url = Bundle.main.url(forResource: "desktop", withExtension: "jpeg"),
           let image = NSImage(contentsOf: url),
           image.size.width > 0,
           image.size.height > 0 {
            self.wallpaperImage = image
            return
        }

        if let image = NSImage(named: "desktop"),
           image.size.width > 0,
           image.size.height > 0 {
            self.wallpaperImage = image
            return
        }

        if let screen = NSScreen.main,
           let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let image = NSImage(contentsOf: url),
           image.size.width > 0,
           image.size.height > 0 {
            self.wallpaperImage = image
            return
        }
    }
}
