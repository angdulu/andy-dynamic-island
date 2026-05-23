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
    weak var webView: WKWebView?

    init(stateManager: AndySystemStateManager) {
        self.stateManager = stateManager
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "andyRequestSystemState" else { return }
        sendState()
    }

    func sendState() {
        let typing = stateManager.isTyping ? "true" : "false"
        let hot = stateManager.isHot ? "true" : "false"
        let idle = stateManager.isIdle ? "true" : "false"
        let transcribing = stateManager.isTranscribing ? "true" : "false"
        let js = """
            if (window.AndyNotch && window.AndyNotch.setSystemState) {
              window.AndyNotch.setSystemState({
                typing: \(typing),
                hot: \(hot),
                idle: \(idle),
                playing: false,
                transcribing: \(transcribing),
                mouseX: \(stateManager.mouseX),
                mouseY: \(stateManager.mouseY)
              });
            }
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

@MainActor
final class AndySystemStateManager: ObservableObject {
    @Published private(set) var isTyping = false
    @Published private(set) var isIdle = false
    @Published private(set) var mouseX: CGFloat = 0.5
    @Published private(set) var mouseY: CGFloat = 0.5
    @Published private(set) var isHot = false
    @Published private(set) var isTranscribing = false

    private var typingResetTask: DispatchWorkItem?
    private var lastActivityDate = Date()
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
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

        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkIdleState()
            }
        }

        DictationManager.shared.$isTranscribing
            .receive(on: RunLoop.main)
            .sink { [weak self] isTranscribing in
                self?.isTranscribing = isTranscribing
            }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        monitors.forEach { NSEvent.removeMonitor($0) }
    }

    @objc private func updateThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        isHot = state == .serious || state == .critical
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
            }
        } else if mouseX != 0.5 || mouseY != 0.5 {
            mouseX = 0.5
            mouseY = 0.5
        }
    }

    private func handleTyping() {
        lastActivityDate = Date()
        isTyping = true

        typingResetTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.isTyping = false
        }
        typingResetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: task)
    }

    private func checkIdleState() {
        isIdle = Date().timeIntervalSince(lastActivityDate) > 60.0
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
        context.coordinator.stateHandler?.sendState()
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
