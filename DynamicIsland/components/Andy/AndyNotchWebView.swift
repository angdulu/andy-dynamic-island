import AppKit
import Combine
import SwiftUI
import WebKit

private final class AndyURLSchemeHandler: NSObject, WKURLSchemeHandler {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else { return }

        var path = requestURL.path
        if path.hasPrefix("/") {
            path.removeFirst()
        }

        var resourceURL = rootURL.appendingPathComponent(path)
        if !FileManager.default.fileExists(atPath: resourceURL.path),
           path.hasPrefix("macbook-pet/"),
           path.hasSuffix(".json") {
            let filename = URL(fileURLWithPath: path).lastPathComponent
            let animationsURL = rootURL
                .appendingPathComponent("assets")
                .appendingPathComponent("animations")

            if let foundURL = findFileRecursively(name: filename, in: animationsURL) {
                resourceURL = foundURL
            }
        }

        guard FileManager.default.fileExists(atPath: resourceURL.path) else {
            urlSchemeTask.didFailWithError(NSError(domain: "AndyNotch", code: 404, userInfo: nil))
            return
        }

        do {
            let data = try Data(contentsOf: resourceURL)
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": mimeType(for: resourceURL),
                    "Access-Control-Allow-Origin": "*",
                    "Cache-Control": "no-cache"
                ]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func findFileRecursively(name: String, in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.nameKey],
            options: [.skipsHiddenFiles]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent == name {
                return fileURL
            }
        }
        return nil
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html"
        case "js": return "application/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}

private final class AndyStateRequestHandler: NSObject, WKScriptMessageHandler {
    let stateManager: AndySystemStateManager
    weak var webView: WKWebView? {
        didSet { stateManager.register(webView: webView) }
    }

    init(stateManager: AndySystemStateManager) {
        self.stateManager = stateManager
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "andyRequestSystemState" else { return }
        stateManager.flush(force: true)
    }
}

/// Owns every system signal Andy reacts to. Shared, because both the expanded
/// panel and the closed notch wing render him — one set of event monitors and
/// one bridge flush feeds however many web views are mounted.
@MainActor
final class AndySystemStateManager: ObservableObject {
    static let shared = AndySystemStateManager()

    // Deliberately not @Published: these change at input-event rates, and
    // republishing them invalidated the SwiftUI view (and re-evaluated JS) on
    // every single mouse move. The bridge is pushed by `flushTimer` instead.
    private var isTyping = false
    private var isIdle = false
    private var mouseX: CGFloat = 0.5
    private var mouseY: CGFloat = 0.5
    private var isHot = false
    private var isRecording = false
    private var isTranscribing = false
    private var voiceFailed = false
    private var voiceLevel: Double = 0

    private var typingResetTask: DispatchWorkItem?
    private var lastActivityDate = Date()
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var idleTimer: Timer?
    private var flushTimer: Timer?
    private var webViews: [WeakWebView] = []
    private var isDirty = true

    private struct WeakWebView {
        weak var value: WKWebView?
    }

    private static let flushInterval = 1.0 / 30.0

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateThermalState),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        updateThermalState()

        if let keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTyping()
            }
        }) {
            monitors.append(keyboardMonitor)
        }

        if let mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleMouseMoved(event)
            }
        }) {
            monitors.append(mouseMonitor)
        }

        let idle = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkIdleState()
            }
        }
        idleTimer = idle
        RunLoop.main.add(idle, forMode: .common)

        let flush = Timer(timeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flush()
            }
        }
        flushTimer = flush
        RunLoop.main.add(flush, forMode: .common)

        let dictation = DictationManager.shared
        dictation.$isTranscribing
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.isTranscribing = value
                self.isDirty = true
            }
            .store(in: &cancellables)

        dictation.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.isRecording = value
                if value { self.voiceFailed = false }
                self.isDirty = true
            }
            .store(in: &cancellables)

        dictation.$inputLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.voiceLevel = value
                self.isDirty = true
            }
            .store(in: &cancellables)

        // A transcription error is what separates the "error" resolve from the
        // "success" resolve on the JS side.
        dictation.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                guard let self else { return }
                if error != nil { self.voiceFailed = true; self.isDirty = true }
            }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        monitors.forEach { NSEvent.removeMonitor($0) }
        idleTimer?.invalidate()
        flushTimer?.invalidate()
    }

    fileprivate func register(webView: WKWebView?) {
        webViews.removeAll { $0.value == nil || $0.value === webView }
        if let webView {
            webViews.append(WeakWebView(value: webView))
        }
        isDirty = true
    }

    /// Coalesces every signal change into at most one `evaluateJavaScript` per
    /// flush interval, instead of one per input event.
    fileprivate func flush(force: Bool = false) {
        webViews.removeAll { $0.value == nil }
        guard !webViews.isEmpty else { return }
        guard force || isDirty else { return }
        isDirty = false

        let js = """
            if (window.AndyNotch && window.AndyNotch.setSystemState) {
              window.AndyNotch.setSystemState({
                typing: \(isTyping),
                hot: \(isHot),
                idle: \(isIdle),
                playing: false,
                recording: \(isRecording),
                transcribing: \(isTranscribing),
                voiceFailed: \(voiceFailed),
                voiceLevel: \(String(format: "%.4f", voiceLevel)),
                mouseX: \(mouseX),
                mouseY: \(mouseY)
              });
            }
        """
        for entry in webViews {
            entry.value?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    @objc private func updateThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        isHot = state == .serious || state == .critical
        isDirty = true
    }

    private func handleMouseMoved(_ event: NSEvent) {
        lastActivityDate = Date()
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }

        let upperHalfStartY = screen.frame.minY + screen.frame.height * 0.5
        if point.y > upperHalfStartY {
            let relativeX = ((point.x - screen.frame.minX) / screen.frame.width).clampedUnit
            let relativeY = ((point.y - upperHalfStartY) / (screen.frame.height * 0.5)).clampedUnit
            if abs(mouseX - relativeX) > 0.005 || abs(mouseY - relativeY) > 0.005 {
                mouseX = relativeX
                mouseY = relativeY
                isDirty = true
            }
        } else if mouseX != 0.5 || mouseY != 0.5 {
            mouseX = 0.5
            mouseY = 0.5
            isDirty = true
        }
    }

    private func handleTyping() {
        lastActivityDate = Date()
        if !isTyping {
            isTyping = true
            isDirty = true
        }

        typingResetTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isTyping = false
            self.isDirty = true
        }
        typingResetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: task)
    }

    private static let idleEventTypes: [CGEventType] = [
        .mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel
    ]

    /// 60s, matching the original feel. The source is real system HID idle
    /// rather than "this app saw no events", so it no longer counts you as idle
    /// while you're active in another window.
    private func checkIdleState() {
        let systemIdle = Self.idleEventTypes
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .greatestFiniteMagnitude
        let appIdle = Date().timeIntervalSince(lastActivityDate)
        let newValue = min(systemIdle, appIdle) > 60.0
        if newValue != isIdle {
            isIdle = newValue
            isDirty = true
        }
    }
}

private extension CGFloat {
    var clampedUnit: CGFloat {
        Swift.min(1, Swift.max(0, self))
    }
}

struct AndyNotchWebViewMenuActions {
    let isCollapsed: () -> Bool
    let reload: () -> Void
    let showInNotch: () -> Void
    let hideFromNotch: () -> Void
}

private final class AndyNotchWKWebView: WKWebView {
    var menuActions: AndyNotchWebViewMenuActions?

    override func rightMouseDown(with event: NSEvent) {
        guard let menuActions else {
            super.rightMouseDown(with: event)
            return
        }

        let isCollapsed = menuActions.isCollapsed()
        let menu = NSMenu()


        let showItem = NSMenuItem(title: "Show Andy in Notch", action: #selector(showAndyInNotchFromMenu), keyEquivalent: "")
        showItem.target = self
        showItem.isEnabled = isCollapsed
        menu.addItem(showItem)

        let hideItem = NSMenuItem(title: "Hide Andy from Notch", action: #selector(hideAndyFromNotchFromMenu), keyEquivalent: "")
        hideItem.target = self
        hideItem.isEnabled = !isCollapsed
        menu.addItem(hideItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func reloadAndyFromMenu() {
        DispatchQueue.main.async { [weak self] in
            self?.menuActions?.reload()
        }
    }

    @objc private func showAndyInNotchFromMenu() {
        DispatchQueue.main.async { [weak self] in
            self?.menuActions?.showInNotch()
        }
    }

    @objc private func hideAndyFromNotchFromMenu() {
        DispatchQueue.main.async { [weak self] in
            self?.menuActions?.hideFromNotch()
        }
    }
}

struct AndyNotchWebView: NSViewRepresentable {
    let rootURL: URL
    @ObservedObject var stateManager: AndySystemStateManager
    var menuActions: AndyNotchWebViewMenuActions? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(AndyURLSchemeHandler(rootURL: rootURL), forURLScheme: "andy")

        let stateHandler = AndyStateRequestHandler(stateManager: stateManager)
        configuration.userContentController.add(stateHandler, name: "andyRequestSystemState")
        context.coordinator.stateHandler = stateHandler

        let webView = AndyNotchWKWebView(frame: .zero, configuration: configuration)
        webView.menuActions = menuActions
        #if DEBUG
        // Lets Safari's Web Inspector attach to Andy so his live mood, emotion
        // axes and voice phase can be read directly. Debug builds only.
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
        stateHandler.webView = webView
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.enclosingScrollView?.hasVerticalScroller = false
        webView.enclosingScrollView?.hasHorizontalScroller = false
        webView.load(URLRequest(url: URL(string: "andy://app/macbook-pet/index.html")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        (nsView as? AndyNotchWKWebView)?.menuActions = menuActions
    }

    final class Coordinator {
        fileprivate var stateHandler: AndyStateRequestHandler?
    }
}

enum AndyNotchResources {
    static var rootURL: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Andy"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        let sourceURL = URL(fileURLWithPath: #filePath)
        return sourceURL
            .deletingLastPathComponent() // Andy
            .deletingLastPathComponent() // components
            .deletingLastPathComponent() // DynamicIsland
            .appendingPathComponent("Andy")
    }
}
