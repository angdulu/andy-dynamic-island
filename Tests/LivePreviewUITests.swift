import AppKit
import Combine

// View fixture: the production panel is compiled against these observable states
// so its layout and focus behavior can be checked without microphone access.
@MainActor
final class DictationManager: ObservableObject {
    static let shared = DictationManager()
    @Published var isRecording = true
    @Published var isTranscribing = false
    @Published var isRefiningLive = false
    @Published var liveTranscript = "Hello, how are you? 오늘 Andy에서 Whisper 테스트를 했어요. This is a live draft; completed phrases receive light correction."
    @Published var liveNotice: String? = nil
}

@main
struct LivePreviewUITests {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let previousApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        LiveDictationPreviewPanel.shared.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApp, "Live preview stole keyboard focus")
            print("PASS: nonactivating live preview preserves the active app")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            LiveDictationPreviewPanel.shared.hide()
            app.terminate(nil)
        }
        app.run()
    }
}
