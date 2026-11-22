import AppKit
import Combine
import Foundation
import Network
import QuartzCore

enum AndyViewMode: Equatable, Sendable {
    case wing
    case expanded
}

enum AndyMood: String, CaseIterable, Sendable {
    case idle
    case curious
    case happy
    case excited
    case content
    case bored
    case frustrated
    case annoyed
    case sad
    case startled
    case affectionate
    case sleepy
    case sleeping
    case waking
}

enum AndyVoicePhase: Equatable, Sendable {
    case idle
    case arming
    case listening
    case thinking
    case success
    case error

    var isActive: Bool {
        self != .idle
    }
}

enum AndySpecialEffect: Equatable, Sendable {
    case none
    case chargeBurst
    case happyReturn
    case grumpyReturn
    case startledWake
    case dizzy
    case winkLeft
    case winkRight
    case yawn
    case appSwitchPerk
}

struct AndyEmotions: Codable {
    var stimulation: Double = 40
    var happiness: Double = 50
    var confidence: Double = 60
    var social: Double = 40
    var tiredness: Double = 10
    var calmness: Double = 70

    static let baseline = AndyEmotions(
        stimulation: 35,
        happiness: 45,
        confidence: 55,
        social: 30,
        tiredness: 0,
        calmness: 65
    )

    mutating func clampAll() {
        stimulation = max(0, min(100, stimulation))
        happiness = max(0, min(100, happiness))
        confidence = max(0, min(100, confidence))
        social = max(0, min(100, social))
        tiredness = max(0, min(100, tiredness))
        calmness = max(0, min(100, calmness))
    }

    func deriveMood() -> AndyMood {
        if tiredness > 82 && stimulation < 25 { return .sleeping }
        if stimulation > 85 && happiness > 55 { return .excited }
        if calmness < 22 && stimulation > 55 { return .startled }
        if happiness < 18 && social < 25 { return .sad }
        if confidence < 28 && stimulation > 45 { return .frustrated }
        if calmness < 32 && social > 35 { return .annoyed }
        if social > 68 && happiness > 52 { return .affectionate }
        if happiness > 62 && social > 38 { return .happy }
        if stimulation < 22 && tiredness < 50 { return .bored }
        if stimulation > 38 && stimulation < 72 && confidence > 30 { return .curious }
        if happiness > 38 && calmness > 55 { return .content }
        if tiredness > 68 { return .sleepy }
        return .idle
    }
}

struct AndyFrameSnapshot: Sendable {
    let nowMs: Double
    let face: AndyFaceKeyFrame
    let mood: AndyMood
    let pulse: Double
    let breathScale: Double
    let blinkProgress: Double
    let blinkRebound: Double
    let saccadeX: Double
    let saccadeY: Double
    let voicePhase: AndyVoicePhase
    let voicePhaseAmount: Double
    let voiceLevel: Double
    let thinkMorph: Double
    let isHot: Bool
    let isLowBattery: Bool
    let isCharging: Bool
    let isOffline: Bool
    let isLateNight: Bool
    let typingFocusAmount: Double       // 0..1 smooth focused squint during sustained typing
    let happySmileAmount: Double        // 0..1 curved lower-lid smile arc
    let specialEffect: AndySpecialEffect
    let effectProgress: Double
    let returnDropOffsetY: Double
    let lookX: Double
    let lookY: Double
    let swayX: Double
    let swayY: Double
    let tilt: Double
    let squash: Double
    let portholeGuardAmount: Double
    let isPerforming: Bool
}

@MainActor
final class AndyPetEngine {
    static let shared = AndyPetEngine()

    private struct SavedState: Codable {
        var emotions: AndyEmotions
        var savedAt: Double
        var firstSeenAt: Double
        var daysKnown: Int
        var lastSeenDay: String?
    }

    private final class AttachedView {
        weak var view: AndyCanvasNSView?
        let mode: AndyViewMode
        init(view: AndyCanvasNSView, mode: AndyViewMode) {
            self.view = view
            self.mode = mode
        }
    }

    private static let moodBehaviors: [AndyMood: [(String, Double)]] = [
        .idle:         [("idle_blink", 20), ("idle_look", 20), ("gazing", 20), ("eyepose_micro", 15), ("explore", 10), ("curious_observe", 5), ("self_amuse", 5), ("bored", 5)],
        .curious:      [("curious_observe", 25), ("gazing", 20), ("explore", 20), ("eyepose_micro", 10), ("idle_blink", 10), ("self_amuse", 8), ("referencing", 7)],
        .happy:        [("happy_react", 25), ("content_calm", 15), ("affectionate", 10), ("excited_dance", 10), ("self_amuse", 10), ("eyepose_micro", 10), ("idle_blink", 10), ("face_react", 10)],
        .excited:      [("excited_dance", 30), ("happy_react", 20), ("self_amuse", 15), ("dance_full", 15), ("eyepose_micro", 10), ("curious_observe", 10)],
        .content:      [("content_calm", 25), ("idle_look", 20), ("gazing", 15), ("eyepose_micro", 15), ("happy_react", 10), ("affectionate", 10), ("idle_blink", 5)],
        .bored:        [("bored", 25), ("gazing", 20), ("idle_look", 15), ("explore", 15), ("eyepose_micro", 10), ("self_amuse", 10), ("hiking", 5)],
        .frustrated:   [("frustrated_react", 30), ("annoyed_react", 20), ("eyepose_micro", 15), ("block_react", 10), ("bored", 10), ("sad_react", 10), ("feedback_negative", 5)],
        .annoyed:      [("annoyed_react", 30), ("frustrated_react", 15), ("feedback_negative", 15), ("eyepose_micro", 15), ("bored", 10), ("startled_react", 10), ("idle_blink", 5)],
        .sad:          [("sad_react", 30), ("bored", 20), ("eyepose_micro", 15), ("idle_blink", 15), ("idle_look", 10), ("sleepy", 10)],
        .startled:     [("startled_react", 35), ("cliff_react", 20), ("curious_observe", 20), ("eyepose_micro", 15), ("explore", 10)],
        .affectionate: [("affectionate", 30), ("happy_react", 20), ("petting_response", 15), ("content_calm", 10), ("face_react", 10), ("eyepose_micro", 10), ("feedback_positive", 5)],
        .sleepy:       [("sleepy", 30), ("idle_blink", 20), ("eyepose_micro", 15), ("idle_look", 15), ("gazing", 10), ("bored", 10)],
        .sleeping:     [("sleeping", 80), ("sleepy", 20)],
        .waking:       [("waking", 40), ("curious_observe", 25), ("eyepose_micro", 15), ("greeting_hello", 10), ("idle_blink", 10)]
    ]

    nonisolated static let wingVirtualDiameter: Double = 80.0 / 0.93
    nonisolated static let wingVisibleHalfWidth: Double = (80.0 / 0.93) / 2.0
    nonisolated static let maxGazeEyeClip: Double = 0.15
    nonisolated static let guardEyeClip: Double = 0.22
    nonisolated static let maxHardEyeClip: Double = 0.28
    nonisolated static let wingBaseScale: Double = 0.99
    private static let portholeGraceMs: Double = 500
    private static let portholeReleaseMs: Double = 300

    private static let saveKey = "andyPetState_v1"
    private static let lastWakeupDateKey = "andyLastWakeupDate"
    private static let voiceResolveMs: Double = 900
    private static let moodDwellMs: Double = 1200

    private let library = AndyAnimationLibrary.shared
    private var emotions = AndyEmotions()
    private var mood: AndyMood = .idle
    private var moodCandidate: AndyMood = .idle
    private var moodCandidateSinceMs: Double = 0

    private var firstSeenAt: Double = Date().timeIntervalSince1970 * 1000
    private var daysKnown: Int = 1
    private var lastSeenDay: String?
    private var greetedToday = false
    private var lastGreetingDay: Int = -1

    private var currentClip: AndyAnimationClip = .fallback
    private var currentClipIndex: Int = -1
    private var clipStartedAtMs: Double = 0
    private var nextAnimationAtMs: Double = 0
    private var animQueue: [Int] = []
    private var wasAsleep = false

    private var smoothedFace: AndyFaceKeyFrame?
    private var lastFaceSmoothMs: Double = 0
    private var lastNeedUpdateMs: Double = 0
    private var lastSaveAtMs: Double = 0

    private var lookOffsetX: Double = 0
    private var lookOffsetY: Double = 0
    private var renderLookX: Double = 0
    private var renderLookY: Double = 0
    private var renderSwayX: Double = 0
    private var renderSwayY: Double = 0
    private var renderTilt: Double = 0
    private var renderSquash: Double = 1

    // Special animations, everyday micro-routines & return physics
    private var specialEffect: AndySpecialEffect = .none
    private var effectStartedAtMs: Double = 0
    private var effectDurationMs: Double = 0
    private var returnDropStartedAtMs: Double = 0
    private var returnDropDurationMs: Double = 520
    private var nextMicroRoutineAtMs: Double = 0
    private var lastAppSwitchAtMs: Double = 0
    private var lastActiveBundleID: String?

    // Smooth everyday expression states
    private var typingStartedAtMs: Double = 0
    private var typingFocusAmount: Double = 0
    private var happySmileAmount: Double = 0
    private var smileBoostUntilMs: Double = 0

    private var isDistracted = false
    private var nextDistractionAtMs: Double = 0
    private var distractionOffsetX: Double = 0
    private var distractionOffsetY: Double = 0
    private var hasDistractionOffset = false

    private var nextBlinkAtMs: Double = 0
    private var isBlinking = false
    private var blinkProgress: Double = 0
    private var blinkDurationMs: Double = 180
    private var blinkStartedAtMs: Double = 0
    private var blinkEndedAtMs: Double = 0

    private var saccadeX: Double = 0
    private var saccadeY: Double = 0
    private var saccadeTargetX: Double = 0
    private var saccadeTargetY: Double = 0
    private var nextSaccadeAtMs: Double = 0

    private var gazeDirX: Double = 0
    private var gazeDirY: Double = 0
    private var gazeTargetX: Double = 0
    private var gazeTargetY: Double = 0
    private var nextGazeShiftAtMs: Double = 0
    private var gazeAtEdge = false
    private var nextAmuseAtMs: Double = 0
    private var isAmusing = false

    private var portholeOutSinceMs: Double = 0
    private var portholeBackSinceMs: Double = 0
    private var portholeAmount: Double = 0
    private var portholeOffCentre = false

    private var lastInteractionAtMs: Double = 0
    private var lastClickAtMs: Double = 0
    private var clickCount: Int = 0
    private var pokeCount: Int = 0
    private var gentleClickWindowMs: [Double] = []
    private var lastMouseSampleX: Double = 0.5
    private var mouseShakeEnergy: Double = 0
    private var lastDizzyAtMs: Double = 0
    private var typingBurstCount: Int = 0

    private var isTyping = false
    private var isIdle = false
    private var isHot = false
    private var isLowBattery = false
    private var isCharging = false
    private var wasPluggedIn: Bool? = nil
    private var isOffline = false
    private var wasOffline: Bool? = nil
    private var isRecording = false
    private var isTranscribing = false
    private var voiceFailed = false
    private var mouseX: Double = 0.5
    private var mouseY: Double = 0.5
    private var hasCursor = false
    private var smoothCursorX: Double = 0.5
    private var smoothCursorY: Double = 0.5
    private var cursorWasNear = false
    private var lastActivityDate = Date()
    private var lastMouseProcessSec: CFTimeInterval = 0
    private var typingResetTask: DispatchWorkItem?
    private var voiceArmingTask: DispatchWorkItem?

    private var sawMusicWhileHidden = false
    private var sawPrivacyWhileHidden = false
    private var sawBatteryHUDWhileHidden = false
    private var pendingChargeBurstUntil: Date?

    private var voicePhase: AndyVoicePhase = .idle
    private var voicePhaseAmount: Double = 0
    private var voiceResolveAtMs: Double = 0
    private var voiceRawLevel: Double = 0
    private var voiceLevel: Double = 0
    private var thinkMorph: Double = 0
    private var lastVoiceUpdateMs: Double = 0

    private var attachedViews: [UUID: AttachedView] = [:]
    private var renderTimer: Timer?
    private var currentTimerInterval: TimeInterval = 0
    private var idleTimer: Timer?
    private var isScreenAsleep = false
    private var wingUnmountedAt: Date?
    private var expandedUnmountedAt: Date?
    private var hasStarted = false

    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?

    private(set) var latestSnapshot: AndyFrameSnapshot?

    private static let idleEventTypes: [CGEventType] = [
        .mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel
    ]

    private init() {
        let nowMs = Self.nowMs()
        moodCandidateSinceMs = nowMs
        lastFaceSmoothMs = nowMs
        lastNeedUpdateMs = nowMs
        lastVoiceUpdateMs = nowMs
        lastInteractionAtMs = nowMs
        lastSaveAtMs = nowMs
        nextBlinkAtMs = nowMs + 3000 + Double.random(in: 0...5000)
        nextSaccadeAtMs = nowMs + 1000 + Double.random(in: 0...3000)
        nextGazeShiftAtMs = nowMs + 2000
        nextAmuseAtMs = nowMs + 30000 + Double.random(in: 0...45000)
        nextMicroRoutineAtMs = nowMs + 16000 + Double.random(in: 0...22000)

        loadPersistedState()
        setupSystemObservers()
    }

    private static func nowMs() -> Double {
        CACurrentMediaTime() * 1000.0
    }

    private func triggerEffect(_ effect: AndySpecialEffect, durationMs: Double) {
        specialEffect = effect
        effectStartedAtMs = Self.nowMs()
        effectDurationMs = durationMs
        updateRenderTimer()
    }

    private func triggerReturnDrop() {
        returnDropStartedAtMs = Self.nowMs()
        updateRenderTimer()
    }

    func attach(view: AndyCanvasNSView, id: UUID, mode: AndyViewMode) {
        ensureStarted()
        let wasEmpty = attachedViews.isEmpty
        attachedViews[id] = AttachedView(view: view, mode: mode)

        if mode == .wing, let unmounted = wingUnmountedAt {
            let nowDate = Date()
            let sinceWing = nowDate.timeIntervalSince(unmounted)
            let sinceExpanded = expandedUnmountedAt.map { nowDate.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            if let until = pendingChargeBurstUntil, nowDate <= until {
                pendingChargeBurstUntil = nil
                triggerReturnDrop()
                triggerEffect(.chargeBurst, durationMs: 2200)
                smileBoostUntilMs = Self.nowMs() + 2400
                playBehaviorCategory("happy_react", immediate: true)
            } else if sawBatteryHUDWhileHidden {
                triggerReturnDrop()
            } else if sinceWing >= 2.5 && sinceExpanded > 2.0 {
                triggerReturnDrop()
                handleContextAwareReturn()
            }
            wingUnmountedAt = nil
            sawMusicWhileHidden = false
            sawPrivacyWhileHidden = false
            sawBatteryHUDWhileHidden = false
        }

        if wasEmpty {
            let now = Self.nowMs()
            lastFaceSmoothMs = now
            lastNeedUpdateMs = now
            lastVoiceUpdateMs = now
            startIdleTimerIfNeeded()
        }

        stepAndPublish(forceDraw: true)
        updateRenderTimer()
    }

    private func handleContextAwareReturn() {
        if sawMusicWhileHidden && !sawPrivacyWhileHidden {
            if Double.random(in: 0...1) < 0.75 {
                emotions.happiness = min(100, emotions.happiness + 18)
                emotions.stimulation = min(100, emotions.stimulation + 15)
                emotions.calmness = min(100, emotions.calmness + 8)
                triggerEffect(.happyReturn, durationMs: 2400)
                smileBoostUntilMs = Self.nowMs() + 2600
                playBehaviorCategory(Double.random(in: 0...1) < 0.5 ? "excited_dance" : "happy_react", immediate: true)
            } else {
                emotions.calmness = max(0, emotions.calmness - 30)
                emotions.happiness = max(0, emotions.happiness - 15)
                emotions.stimulation = min(100, emotions.stimulation + 20)
                triggerEffect(.grumpyReturn, durationMs: 1800)
                playBehaviorCategory("annoyed_react", immediate: true)
            }
        } else {
            emotions.calmness = max(0, emotions.calmness - 45)
            emotions.happiness = max(0, emotions.happiness - 25)
            emotions.stimulation = min(100, emotions.stimulation + 30)
            triggerEffect(.grumpyReturn, durationMs: 1800)
            playBehaviorCategory("annoyed_react", immediate: true)
        }
    }

    func detach(id: UUID) {
        guard let removed = attachedViews.removeValue(forKey: id) else { return }
        let now = Date()
        if removed.mode == .wing {
            wingUnmountedAt = now
            if MusicManager.shared.isPlaying || !MusicManager.shared.isPlayerIdle {
                sawMusicWhileHidden = true
            }
            if PrivacyIndicatorManager.shared.microphoneActive || PrivacyIndicatorManager.shared.cameraActive {
                sawPrivacyWhileHidden = true
            }
            if BatteryStatusViewModel.shared.activeTemporaryHUDKind != nil {
                sawBatteryHUDWhileHidden = true
            }
        } else {
            expandedUnmountedAt = now
        }

        pruneDeadViews()
        if attachedViews.isEmpty {
            savePersistedState()
            stopRenderTimer()
            stopIdleTimer()
        } else {
            updateRenderTimer()
        }
    }

    func reload() {
        let now = Self.nowMs()
        smoothedFace = nil
        lastFaceSmoothMs = now
        let keepalive = library.findIndices(matching: "keepalive_eyes")
        if let pick = keepalive.first {
            loadClip(at: pick)
        }
        stepAndPublish(forceDraw: true)
    }

    func handleTap() {
        let now = Self.nowMs()
        let rapid = (now - lastClickAtMs) < 600
        lastInteractionAtMs = now
        lastClickAtMs = now
        clickCount += 1

        if rapid {
            applyInteraction(.rapidClick)
            pokeCount += 1
            if pokeCount >= 3 {
                triggerEffect(.grumpyReturn, durationMs: 1400)
                playBehaviorCategory("annoyed_react", immediate: true)
                pokeCount = 0
            }
        } else {
            applyInteraction(.gentleClick)
            pokeCount = 0
            smileBoostUntilMs = now + 2200
            // Playful occasional wink on gentle tap
            if Double.random(in: 0...1) < 0.35 && specialEffect == .none {
                triggerEffect(Bool.random() ? .winkLeft : .winkRight, durationMs: 650)
            }
        }

        gentleClickWindowMs.append(now)
        while let first = gentleClickWindowMs.first, now - first > 5000 {
            gentleClickWindowMs.removeFirst()
        }
        let rate = Double(gentleClickWindowMs.count) / 5.0
        if rate > 0.4 && rate < 1.5 && animQueue.isEmpty {
            applyInteraction(.petting)
            smileBoostUntilMs = now + 3500
            let tag = rate < 0.7 ? "petting_lvl1" : (rate < 1.2 ? "petting_lvl2" : "petting_blissloop")
            playBehaviorCategory(tag)
        }

        if clickCount % 10 == 0 {
            if emotions.happiness > 70 { playBehaviorCategory("feedback_positive") }
            else if emotions.calmness < 30 { playBehaviorCategory("feedback_negative") }
        }

        wakeFromSleepIfNeeded(startle: rapid)
        updateRenderTimer()
    }

    func handleDrag() {
        let now = Self.nowMs()
        lastInteractionAtMs = now
        applyInteraction(.drag)
        wakeFromSleepIfNeeded(startle: true)
        updateRenderTimer()
    }

    private func wakeFromSleepIfNeeded(startle: Bool) {
        if mood == .sleeping || mood == .sleepy {
            let wasDeepSleep = (mood == .sleeping)
            emotions.tiredness = max(0, emotions.tiredness - 35)
            emotions.stimulation = min(100, emotions.stimulation + 35)
            if wasDeepSleep && startle {
                triggerEffect(.startledWake, durationMs: 1100)
                playBehaviorCategory("startled_react", immediate: true)
            }
        }
    }

    private func ensureStarted() {
        guard !hasStarted else { return }
        hasStarted = true
        library.ensureLoaded()

        let hour = Calendar.current.component(.hour, from: Date())
        var startIndices: [Int] = []
        if hour >= 6 && hour < 10 {
            let todayStr = Self.todayDayString()
            if UserDefaults.standard.string(forKey: Self.lastWakeupDateKey) != todayStr {
                startIndices = library.findIndices(matching: "onboarding_wakeup")
                UserDefaults.standard.set(todayStr, forKey: Self.lastWakeupDateKey)
            }
        }
        if startIndices.isEmpty { startIndices = library.findIndices(matching: "keepalive_eyes") }
        if startIndices.isEmpty { startIndices = library.findIndices(matching: "eyepose_curious") }
        if let first = startIndices.first {
            loadClip(at: first)
        } else {
            currentClip = .fallback
            clipStartedAtMs = Self.nowMs()
            scheduleNextAnimation(now: clipStartedAtMs)
        }
    }

    private static func todayDayString() -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }

    private func loadPersistedState() {
        let today = Self.todayDayString()
        guard let data = UserDefaults.standard.data(forKey: Self.saveKey),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data) else {
            firstSeenAt = Date().timeIntervalSince1970 * 1000
            daysKnown = 1
            lastSeenDay = today
            return
        }

        let nowEpochMs = Date().timeIntervalSince1970 * 1000
        let hoursAway = max(0, (nowEpochMs - saved.savedAt) / 3_600_000.0)
        let settled = 1.0 - exp(-hoursAway / 2.0)

        emotions.stimulation = Self.clamp(Self.lerp(saved.emotions.stimulation, AndyEmotions.baseline.stimulation, settled), 0, 100)
        emotions.happiness = Self.clamp(Self.lerp(saved.emotions.happiness, AndyEmotions.baseline.happiness, settled), 0, 100)
        emotions.confidence = Self.clamp(Self.lerp(saved.emotions.confidence, AndyEmotions.baseline.confidence, settled), 0, 100)
        emotions.social = Self.clamp(Self.lerp(saved.emotions.social, AndyEmotions.baseline.social, settled), 0, 100)
        emotions.tiredness = Self.clamp(Self.lerp(saved.emotions.tiredness, AndyEmotions.baseline.tiredness, settled), 0, 100)
        emotions.calmness = Self.clamp(Self.lerp(saved.emotions.calmness, AndyEmotions.baseline.calmness, settled), 0, 100)

        firstSeenAt = saved.firstSeenAt
        daysKnown = max(1, saved.daysKnown)
        lastSeenDay = saved.lastSeenDay
        if lastSeenDay != today {
            daysKnown += 1
            lastSeenDay = today
        }
        mood = emotions.deriveMood()
        moodCandidate = mood
    }

    private func savePersistedState() {
        let state = SavedState(
            emotions: emotions,
            savedAt: Date().timeIntervalSince1970 * 1000,
            firstSeenAt: firstSeenAt,
            daysKnown: daysKnown,
            lastSeenDay: lastSeenDay
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.saveKey)
        }
    }

    private func setupSystemObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateThermalState),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        updateThermalState()

        let wsCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            wsCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isScreenAsleep = true
                    self?.stopRenderTimer()
                }
            }
        )
        workspaceObservers.append(
            wsCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isScreenAsleep = false
                    self?.updateRenderTimer()
                }
            }
        )
        // Everyday event (never covered by Dynamic Island HUD): brief curious perk when switching apps
        workspaceObservers.append(
            wsCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor [weak self] in
                    self?.handleAppSwitch(bundleID: bundleID)
                }
            }
        )

        if let keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTypingEvent()
            }
        }) {
            monitors.append(keyboardMonitor)
        }

        if let mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMouseMovedEvent()
            }
        }) {
            monitors.append(mouseMonitor)
        }

        let dictation = DictationManager.shared
        dictation.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] recording in
                guard let self else { return }
                if recording { self.voiceFailed = false }
                self.updateVoicePipeline(recording: recording, transcribing: self.isTranscribing)
            }
            .store(in: &cancellables)

        dictation.$isTranscribing
            .receive(on: RunLoop.main)
            .sink { [weak self] transcribing in
                guard let self else { return }
                self.updateVoicePipeline(recording: self.isRecording, transcribing: transcribing)
            }
            .store(in: &cancellables)

        dictation.$inputLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.voiceRawLevel = Self.clamp(level, 0, 1)
            }
            .store(in: &cancellables)

        dictation.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                guard let self, error != nil else { return }
                self.voiceFailed = true
            }
            .store(in: &cancellables)

        let battery = BatteryStatusViewModel.shared
        battery.$isPluggedIn
            .combineLatest(battery.$isCharging, battery.$levelBattery, battery.$maxCapacity)
            .receive(on: RunLoop.main)
            .sink { [weak self] pluggedIn, charging, level, maxCap in
                guard let self else { return }
                let pct = maxCap > 0 ? (Double(level) / Double(maxCap) * 100.0) : Double(level)
                self.isCharging = charging || pluggedIn
                self.isLowBattery = !pluggedIn && pct > 0 && pct <= 20.0

                if let prev = self.wasPluggedIn, !prev && pluggedIn {
                    self.emotions.stimulation = min(100, self.emotions.stimulation + 22)
                    self.emotions.happiness = min(100, self.emotions.happiness + 18)
                    self.emotions.tiredness = max(0, self.emotions.tiredness - 20)
                    self.pendingChargeBurstUntil = Date().addingTimeInterval(10.0)
                    if !self.attachedViews.isEmpty && BatteryStatusViewModel.shared.activeTemporaryHUDKind == nil {
                        self.pendingChargeBurstUntil = nil
                        self.triggerEffect(.chargeBurst, durationMs: 2200)
                        self.smileBoostUntilMs = Self.nowMs() + 2400
                        self.playBehaviorCategory("happy_react", immediate: true)
                    }
                }
                self.wasPluggedIn = pluggedIn
            }
            .store(in: &cancellables)

        battery.$activeTemporaryHUDKind
            .receive(on: RunLoop.main)
            .sink { [weak self] kind in
                guard let self else { return }
                if kind != nil && self.wingUnmountedAt != nil {
                    self.sawBatteryHUDWhileHidden = true
                }
            }
            .store(in: &cancellables)

        MusicManager.shared.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                guard let self else { return }
                if playing && self.wingUnmountedAt != nil {
                    self.sawMusicWhileHidden = true
                }
            }
            .store(in: &cancellables)

        PrivacyIndicatorManager.shared.$microphoneActive
            .combineLatest(PrivacyIndicatorManager.shared.$cameraActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] mic, cam in
                guard let self else { return }
                if (mic || cam) && self.wingUnmountedAt != nil {
                    self.sawPrivacyWhileHidden = true
                }
            }
            .store(in: &cancellables)

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = (path.status != .satisfied)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOffline = offline
                if let prev = self.wasOffline, prev != offline, !self.attachedViews.isEmpty {
                    if offline {
                        self.playBehaviorCategory("explore", immediate: true)
                    } else {
                        self.emotions.happiness = min(100, self.emotions.happiness + 8)
                        self.smileBoostUntilMs = Self.nowMs() + 2000
                        self.playBehaviorCategory("happy_react")
                    }
                }
                self.wasOffline = offline
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    private func handleAppSwitch(bundleID: String?) {
        guard let bundleID, bundleID != lastActiveBundleID else { return }
        lastActiveBundleID = bundleID
        // Ignore our own app activation (e.g. opening Settings)
        if bundleID == Bundle.main.bundleIdentifier { return }
        guard !attachedViews.isEmpty, !isScreenAsleep, !voicePhase.isActive, mood != .sleeping else { return }

        let now = Self.nowMs()
        guard now - lastAppSwitchAtMs > 8000, specialEffect == .none else { return }
        lastAppSwitchAtMs = now
        emotions.stimulation = min(100, emotions.stimulation + 4)
        triggerEffect(.appSwitchPerk, durationMs: 750)
    }

    @objc private func updateThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        isHot = (state == .serious || state == .critical)
    }

    @objc private func handleAppWillTerminate() {
        savePersistedState()
    }

    private func handleTypingEvent() {
        lastActivityDate = Date()
        guard !attachedViews.isEmpty, !isScreenAsleep else { return }

        if mood == .sleeping {
            wakeFromSleepIfNeeded(startle: true)
        }

        let now = Self.nowMs()
        if !isTyping {
            isTyping = true
            typingStartedAtMs = now
            applyInteraction(.typing)
        }

        typingBurstCount += 1
        let scanX = sin(Double(typingBurstCount) * 0.55) * 6.0
        lookOffsetX = scanX
        lookOffsetY = 14.0

        typingResetTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isTyping = false
            self.typingBurstCount = 0
            self.typingStartedAtMs = 0
            self.lookOffsetX = 0
            self.lookOffsetY = 0
        }
        typingResetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: task)
    }

    private func handleMouseMovedEvent() {
        guard !attachedViews.isEmpty, !isScreenAsleep else { return }
        let nowSec = CACurrentMediaTime()
        guard nowSec - lastMouseProcessSec >= (1.0 / 24.0) else { return }
        lastMouseProcessSec = nowSec
        lastActivityDate = Date()

        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }

        let upperHalfStartY = screen.frame.minY + screen.frame.height * 0.5
        if point.y > upperHalfStartY {
            let relX = Self.clamp(Double((point.x - screen.frame.minX) / screen.frame.width), 0, 1)
            let relY = Self.clamp(Double((point.y - upperHalfStartY) / (screen.frame.height * 0.5)), 0, 1)

            let dx = abs(relX - lastMouseSampleX)
            lastMouseSampleX = relX
            mouseShakeEnergy = max(0, mouseShakeEnergy * 0.86 + dx)
            let nowMs = Self.nowMs()
            if mouseShakeEnergy > 1.35 && (nowMs - lastDizzyAtMs) > 12_000 && !voicePhase.isActive {
                lastDizzyAtMs = nowMs
                mouseShakeEnergy = 0
                emotions.stimulation = min(100, emotions.stimulation + 18)
                triggerEffect(.dizzy, durationMs: 1800)
                playBehaviorCategory("startled_react", immediate: true)
            }

            if mood == .sleeping && dx > 0.08 {
                wakeFromSleepIfNeeded(startle: true)
            }

            if abs(mouseX - relX) > 0.005 || abs(mouseY - relY) > 0.005 {
                mouseX = relX
                mouseY = relY
                hasCursor = true
            }
        } else if mouseX != 0.5 || mouseY != 0.5 {
            mouseX = 0.5
            mouseY = 0.5
            mouseShakeEnergy *= 0.7
        }
    }

    private func startIdleTimerIfNeeded() {
        guard idleTimer == nil else { return }
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkIdleState()
            }
        }
        timer.tolerance = 1.0
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func checkIdleState() {
        let systemIdle = Self.idleEventTypes
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .greatestFiniteMagnitude
        let appIdle = Date().timeIntervalSince(lastActivityDate)
        let newIdle = min(systemIdle, appIdle) > 60.0
        guard newIdle != isIdle else { return }
        isIdle = newIdle
        if newIdle {
            emotions.tiredness = 95
            emotions.stimulation = 5
        } else {
            let wasSleeping = (mood == .sleeping)
            emotions.tiredness = 10
            emotions.stimulation = 50
            let now = Self.nowMs()
            if now - lastInteractionAtMs > 3000 {
                lastInteractionAtMs = now
                applyInteraction(.mouseMove)
            }
            if wasSleeping {
                triggerEffect(.startledWake, durationMs: 1000)
                playBehaviorCategory("waking", immediate: true)
            }
        }
        updateRenderTimer()
    }

    private func updateVoicePipeline(recording: Bool, transcribing: Bool) {
        let prevRecording = isRecording
        let prevTranscribing = isTranscribing
        isRecording = recording
        isTranscribing = transcribing
        guard recording != prevRecording || transcribing != prevTranscribing else { return }

        voiceArmingTask?.cancel()
        voiceArmingTask = nil

        if recording {
            if !prevRecording {
                setVoicePhase(.arming)
                let task = DispatchWorkItem { [weak self] in
                    guard let self, self.isRecording else { return }
                    self.setVoicePhase(.listening)
                }
                voiceArmingTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: task)
            }
        } else if transcribing {
            setVoicePhase(.thinking)
        } else if voiceFailed {
            setVoicePhase(.error)
        } else if prevTranscribing || prevRecording {
            setVoicePhase(.success)
        } else {
            setVoicePhase(.idle)
        }
        updateRenderTimer()
    }

    private func setVoicePhase(_ phase: AndyVoicePhase) {
        guard voicePhase != phase else { return }
        let now = Self.nowMs()
        voicePhase = phase
        voiceResolveAtMs = (phase == .success || phase == .error) ? now + Self.voiceResolveMs : 0

        switch phase {
        case .arming:
            voiceRawLevel = 0
            voiceLevel = 0
        case .listening:
            emotions.stimulation = min(100, emotions.stimulation + 18)
            emotions.social = min(100, emotions.social + 8)
            emotions.calmness = max(0, emotions.calmness - 8)
        case .thinking:
            emotions.stimulation = min(100, emotions.stimulation + 8)
        case .success:
            emotions.happiness = min(100, emotions.happiness + 10)
            emotions.confidence = min(100, emotions.confidence + 8)
            smileBoostUntilMs = now + 1800
        case .error:
            emotions.confidence = max(0, emotions.confidence - 15)
            emotions.happiness = max(0, emotions.happiness - 8)
        case .idle:
            break
        }
    }

    private func pruneDeadViews() {
        attachedViews = attachedViews.filter { $0.value.view != nil }
    }

    private func hasActiveMotionBurst(now: Double) -> Bool {
        if specialEffect != .none { return true }
        if returnDropStartedAtMs > 0 && (now - returnDropStartedAtMs) < returnDropDurationMs { return true }
        if blinkEndedAtMs > 0 && (now - blinkEndedAtMs) < 220 { return true }
        return false
    }

    private func desiredFrameInterval() -> TimeInterval? {
        pruneDeadViews()
        guard !attachedViews.isEmpty, !isScreenAsleep else { return nil }

        let now = Self.nowMs()
        let hasExpanded = attachedViews.values.contains { $0.mode == .expanded }
        if voicePhase.isActive || thinkMorph > 0.002 || hasExpanded {
            return 1.0 / 60.0
        }
        if isBlinking || hasActiveMotionBurst(now: now) {
            return 1.0 / 30.0
        }
        if mood == .sleeping {
            return 1.0 / 12.0
        }
        if mood == .sleepy || isLowBattery {
            return 1.0 / 15.0
        }
        return 1.0 / 24.0
    }

    private func updateRenderTimer() {
        guard let target = desiredFrameInterval() else {
            stopRenderTimer()
            return
        }
        if renderTimer != nil && abs(currentTimerInterval - target) < 0.001 {
            return
        }
        stopRenderTimer()
        currentTimerInterval = target
        let timer = Timer(timeInterval: target, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer.tolerance = target >= (1.0 / 25.0) ? min(0.008, target * 0.15) : 0.001
        renderTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRenderTimer() {
        renderTimer?.invalidate()
        renderTimer = nil
        currentTimerInterval = 0
    }

    private func tick() {
        pruneDeadViews()
        guard !attachedViews.isEmpty, !isScreenAsleep else {
            stopRenderTimer()
            return
        }
        stepAndPublish(forceDraw: false)
        updateRenderTimer()
    }

    private func stepAndPublish(forceDraw: Bool) {
        let now = Self.nowMs()

        updateNeeds(now: now)
        updateVoice(now: now)
        updateBlink(now: now)
        updateSaccade(now: now)
        updateGazeTracking(now: now)
        updateEverydayMicroRoutines(now: now)

        if !voicePhase.isActive && now > nextAnimationAtMs {
            playNextAnimation()
        }

        if now - lastSaveAtMs > 30_000 {
            lastSaveAtMs = now
            savePersistedState()
        }

        var effectProgress = 0.0
        if specialEffect != .none {
            let elapsed = now - effectStartedAtMs
            if elapsed >= effectDurationMs {
                specialEffect = .none
                effectProgress = 0.0
            } else {
                effectProgress = Self.clamp(elapsed / max(1.0, effectDurationMs), 0, 1)
            }
        }

        var dropY = 0.0
        if returnDropStartedAtMs > 0 {
            let elapsed = now - returnDropStartedAtMs
            if elapsed >= returnDropDurationMs {
                returnDropStartedAtMs = 0
            } else {
                let t = elapsed / returnDropDurationMs
                dropY = -26.0 * exp(-6.2 * t) * cos(t * .pi * 2.2)
            }
        }

        var blinkRebound = 0.0
        if blinkEndedAtMs > 0 {
            let elapsed = now - blinkEndedAtMs
            if elapsed < 200 {
                let t = elapsed / 200.0
                blinkRebound = sin(t * .pi) * (1.0 - t) * 0.045
            } else {
                blinkEndedAtMs = 0
            }
        }

        let dtScale = Self.clamp((currentTimerInterval > 0 ? currentTimerInterval : 1.0 / 30.0) * 30.0, 0.25, 2.5)

        // Smooth sustained-typing focus squint (kicks in after 1.6s of continuous typing)
        let focusTarget: Double = (isTyping && typingStartedAtMs > 0 && (now - typingStartedAtMs) > 1600 && !voicePhase.isActive) ? 1.0 : 0.0
        typingFocusAmount += (focusTarget - typingFocusAmount) * (1.0 - pow(1.0 - 0.10, dtScale))
        if typingFocusAmount < 0.004 { typingFocusAmount = 0 }

        // Smooth curved happy smile arc (happy/affectionate moods or tap/petting/happy return)
        let wantsSmile = !voicePhase.isActive && mood != .sleeping && mood != .sleepy && (
            now < smileBoostUntilMs ||
            mood == .happy ||
            mood == .affectionate ||
            specialEffect == .happyReturn
        )
        let smileTarget: Double = wantsSmile ? (now < smileBoostUntilMs || specialEffect == .happyReturn ? 1.0 : 0.65) : 0.0
        happySmileAmount += (smileTarget - happySmileAmount) * (1.0 - pow(1.0 - 0.12, dtScale))
        if happySmileAmount < 0.004 { happySmileAmount = 0 }

        let elapsed = max(0, now - clipStartedAtMs)
        let animTime = elapsed.truncatingRemainder(dividingBy: max(1, currentClip.durationMs))
        let rawFace = sampleFaceTrack(currentClip.faceFrames, at: animTime)
        let smoothed = smoothFaceFrame(rawFace, now: now)
        let safe = normalizeFaceForDisplay(smoothed)
        let breathRate = isHot ? 2.0 : (isLowBattery ? 0.65 : 1.0)
        let breath = getBreathScale(now: now * breathRate)
        let pulse = (sin(now / 260.0) + 1.0) / 2.0

        let isPerforming = !animQueue.isEmpty || currentClip.durationMs > 2000
        let idleAmount = isPerforming ? 0.35 : 1.0
        var targetLookX = isPerforming ? 0 : lookOffsetX
        var targetLookY = isPerforming ? 0 : lookOffsetY
        let targetSwayX = sin(now / 2400.0) * 0.9 * idleAmount
        let targetSwayY = sin(now / 1700.0 + 0.8) * 0.7 * idleAmount
        var targetTilt = sin(now / 3600.0 + 0.4) * 0.018 * idleAmount
        var targetSquash = 1.0 + sin(now / 1900.0) * 0.012 * idleAmount

        switch specialEffect {
        case .happyReturn:
            let bounce = abs(sin(effectProgress * .pi * 4.0)) * (1.0 - effectProgress * 0.5)
            targetLookY -= bounce * 5.0
            targetTilt += sin(effectProgress * .pi * 4.0) * 0.07 * (1.0 - effectProgress)
            targetSquash += bounce * 0.06
        case .grumpyReturn:
            let shake = sin(effectProgress * .pi * 7.0) * exp(-2.2 * effectProgress)
            targetLookX += shake * 7.5
            targetTilt += shake * 0.09
        case .startledWake:
            let pop = sin(min(1.0, effectProgress * 2.5) * .pi) * exp(-2.5 * effectProgress)
            targetLookY -= pop * 7.0
            targetSquash += pop * 0.09
        case .dizzy:
            let amp = (1.0 - effectProgress)
            targetLookX += cos(effectProgress * .pi * 6.0) * 6.0 * amp
            targetLookY += sin(effectProgress * .pi * 6.0) * 3.5 * amp
            targetTilt += sin(effectProgress * .pi * 6.0) * 0.10 * amp
        case .chargeBurst:
            let pop = sin(min(1.0, effectProgress * 3.0) * .pi) * (1.0 - effectProgress * 0.4)
            targetSquash += pop * 0.08
        case .winkLeft:
            let s = sin(effectProgress * .pi)
            targetTilt -= 0.075 * s
            targetLookY -= 1.5 * s
        case .winkRight:
            let s = sin(effectProgress * .pi)
            targetTilt += 0.075 * s
            targetLookY -= 1.5 * s
        case .yawn:
            let s = sin(effectProgress * .pi)
            targetLookY -= 3.2 * s
            targetSquash -= 0.055 * s
        case .appSwitchPerk:
            let s = sin(effectProgress * .pi)
            targetLookY -= 2.4 * s
            targetTilt += 0.045 * s
            targetSquash += 0.04 * s
        case .none:
            break
        }

        if thinkMorph > 0 {
            targetLookX = Self.lerp(targetLookX, 0, thinkMorph)
            targetLookY = Self.lerp(targetLookY, 0, thinkMorph)
            targetTilt = Self.lerp(targetTilt, 0, thinkMorph)
        }

        let poseEase = 1.0 - pow(1.0 - (isPerforming ? 0.08 : 0.12), dtScale)
        let swayEase = 1.0 - pow(1.0 - 0.06, dtScale)
        let tiltEase = 1.0 - pow(1.0 - 0.08, dtScale)
        let squashEase = 1.0 - pow(1.0 - 0.10, dtScale)

        renderSwayX += (targetSwayX - renderSwayX) * swayEase
        renderSwayY += (targetSwayY - renderSwayY) * swayEase
        renderTilt += (targetTilt - renderTilt) * tiltEase
        renderSquash += (targetSquash - renderSquash) * squashEase

        let isWingOnly = !attachedViews.values.contains { $0.mode == .expanded }
        let wingScale = Self.wingBaseScale * breath
        let faceSX = Self.lerp(safe.faceScaleX, 1, thinkMorph)
        let squash = Self.lerp(renderSquash, 1, thinkMorph)
        let rawFaceX = Self.lerp(safe.faceCenterX * 1.1, 0, thinkMorph) + renderSwayX * (1 - thinkMorph)
        let eyeXFactor = faceSX * wingScale * squash

        if isWingOnly {
            targetLookX = Self.clampLookXToPorthole(safe: safe, lookX: targetLookX, faceX: rawFaceX, xFactor: eyeXFactor)
        }
        renderLookX += (targetLookX - renderLookX) * poseEase
        renderLookY += (targetLookY - renderLookY) * poseEase

        let guardAmt = updatePortholeGuard(
            safe: safe, now: now, baseX: rawFaceX, xFactor: eyeXFactor, lookX: renderLookX, isWing: isWingOnly, dtScale: dtScale
        )

        let hour = Calendar.current.component(.hour, from: Date())
        let lateNight = (hour >= 23 || hour < 5)

        let snapshot = AndyFrameSnapshot(
            nowMs: now,
            face: safe,
            mood: mood,
            pulse: pulse,
            breathScale: breath,
            blinkProgress: blinkProgress,
            blinkRebound: blinkRebound,
            saccadeX: saccadeX,
            saccadeY: saccadeY,
            voicePhase: voicePhase,
            voicePhaseAmount: voicePhaseAmount,
            voiceLevel: voiceLevel,
            thinkMorph: thinkMorph,
            isHot: isHot,
            isLowBattery: isLowBattery,
            isCharging: isCharging,
            isOffline: isOffline,
            isLateNight: lateNight,
            typingFocusAmount: typingFocusAmount,
            happySmileAmount: happySmileAmount,
            specialEffect: specialEffect,
            effectProgress: effectProgress,
            returnDropOffsetY: dropY,
            lookX: renderLookX,
            lookY: renderLookY,
            swayX: renderSwayX,
            swayY: renderSwayY,
            tilt: renderTilt,
            squash: renderSquash,
            portholeGuardAmount: guardAmt,
            isPerforming: isPerforming
        )
        latestSnapshot = snapshot

        for entry in attachedViews.values {
            entry.view?.updateFrame(snapshot, force: forceDraw)
        }
    }

    private func updateEverydayMicroRoutines(now: Double) {
        guard !voicePhase.isActive, specialEffect == .none, mood != .sleeping else { return }
        guard now > nextMicroRoutineAtMs else { return }

        // Trigger charming everyday moments every ~24–48s while Andy is hanging out
        nextMicroRoutineAtMs = now + 24_000 + Double.random(in: 0...24_000)

        let hour = Calendar.current.component(.hour, from: Date())
        let sleepyBias = (mood == .sleepy || mood == .bored || isLowBattery || hour >= 23 || hour < 6)

        let roll = Double.random(in: 0...1)
        if sleepyBias && roll < 0.60 {
            triggerEffect(.yawn, durationMs: 1750)
        } else if roll < 0.45 {
            triggerEffect(Bool.random() ? .winkLeft : .winkRight, durationMs: 680)
            smileBoostUntilMs = max(smileBoostUntilMs, now + 1100)
        } else if roll < 0.72 {
            triggerEffect(.yawn, durationMs: 1700)
        } else {
            // Brief happy smile moment
            smileBoostUntilMs = max(smileBoostUntilMs, now + 2600)
        }
    }

    private enum InteractionKind {
        case gentleClick, rapidClick, drag, mouseNear, mouseMove, typing, petting
    }

    private func applyInteraction(_ kind: InteractionKind) {
        switch kind {
        case .gentleClick:
            emotions.stimulation += 12; emotions.happiness += 8; emotions.social += 10
            emotions.calmness -= 3; emotions.tiredness -= 5
        case .rapidClick:
            emotions.stimulation += 20; emotions.calmness -= 18; emotions.happiness -= 5; emotions.tiredness += 3
        case .drag:
            emotions.stimulation += 25; emotions.calmness -= 25; emotions.happiness -= 10; emotions.social -= 8
        case .mouseNear:
            emotions.social += 4; emotions.stimulation += 2
        case .mouseMove:
            emotions.stimulation += 1
        case .typing:
            emotions.stimulation += 2; emotions.social += 1
        case .petting:
            emotions.happiness += 12; emotions.social += 8; emotions.calmness += 5; emotions.tiredness -= 3
        }
        emotions.clampAll()
    }

    private func updateNeeds(now: Double) {
        let dt = Self.clamp((now - lastNeedUpdateMs) / 1000.0, 0, 0.15)
        lastNeedUpdateMs = now
        let idleSeconds = (now - lastInteractionAtMs) / 1000.0

        let step = min(dt, 0.1) * 60.0
        emotions.stimulation += (35 - emotions.stimulation) * 0.008 * step
        emotions.happiness += (45 - emotions.happiness) * 0.004 * step
        emotions.confidence += (55 - emotions.confidence) * 0.003 * step
        emotions.social += (30 - emotions.social) * 0.005 * step
        emotions.calmness += (65 - emotions.calmness) * 0.006 * step
        emotions.tiredness += 0.015 * step

        if isLowBattery {
            emotions.tiredness += 0.04 * step
            emotions.stimulation -= 0.015 * step
        }

        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 23 || hour < 6 {
            emotions.tiredness += 0.03 * step
            emotions.stimulation -= 0.01 * step
        } else if hour >= 6 && hour < 10 {
            emotions.happiness += 0.005 * step
            emotions.stimulation += 0.005 * step
        }

        if idleSeconds > 30 {
            emotions.stimulation -= 0.02 * step
            emotions.social -= 0.01 * step
        }
        if idleSeconds > 120 {
            emotions.tiredness += 0.04 * step
        }
        emotions.clampAll()

        smoothCursorX += (mouseX - smoothCursorX) * 0.04
        smoothCursorY += (mouseY - smoothCursorY) * 0.04
        let dx = mouseX - 0.5
        let dy = mouseY - 0.5
        let isNear = hasCursor && hypot(dx, dy) < 0.3
        if isNear && !cursorWasNear {
            applyInteraction(.mouseNear)
        }
        cursorWasNear = isNear

        if now > nextGazeShiftAtMs {
            gazeTargetX = Double.random(in: -1...1)
            gazeTargetY = Double.random(in: -0.75...0.75)
            nextGazeShiftAtMs = now + 3000 + Double.random(in: 0...8000)
        }
        gazeDirX += (gazeTargetX - gazeDirX) * 0.02
        gazeDirY += (gazeTargetY - gazeDirY) * 0.02
        let wasAtEdge = gazeAtEdge
        gazeAtEdge = abs(gazeDirX) > 0.85 || abs(gazeDirY) > 0.85
        if !wasAtEdge && gazeAtEdge && animQueue.isEmpty && mood != .sleeping {
            if Double.random(in: 0...1) < 0.35 {
                playBehaviorCategory("cliff_react")
            }
        }

        if now > nextAmuseAtMs && !isAmusing && animQueue.isEmpty && mood != .sleeping {
            isAmusing = true
            nextAmuseAtMs = now + 120_000 + Double.random(in: 0...240_000)
            let roll = Double.random(in: 0...1)
            if roll < 0.35 { playBehaviorCategory("dance_full") }
            else if roll < 0.55 { playBehaviorCategory("keepaway_game") }
            else if roll < 0.70 { playBehaviorCategory("fistbump_game") }
            else if roll < 0.85 { playBehaviorCategory("face_react") }
            else { playBehaviorCategory("referencing") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                self?.isAmusing = false
            }
        }

        let rawMood = emotions.deriveMood()
        if rawMood != moodCandidate {
            moodCandidate = rawMood
            moodCandidateSinceMs = now
        }
        let newMood = (now - moodCandidateSinceMs >= Self.moodDwellMs) ? rawMood : mood

        if newMood == .sleeping && mood != .sleeping {
            wasAsleep = true
            if hour >= 21 || hour < 5, let pick = library.findIndices(matching: "greeting_goodnight").randomElement() {
                animQueue.append(pick)
            }
            if let pick = library.findIndices(matching: "gotosleep_getin").randomElement() {
                animQueue.append(pick)
            }
            let loops = library.findIndices(matching: "gotosleep_sleeping")
            if !loops.isEmpty {
                for _ in 0..<4 {
                    if let p = loops.randomElement() { animQueue.append(p) }
                }
            }
            if !animQueue.isEmpty { playNextAnimation() }
        }

        if wasAsleep && newMood != .sleeping && newMood != .sleepy {
            wasAsleep = false
            if let pick = library.findIndices(matching: "gotosleep_getout").randomElement() {
                animQueue.insert(pick, at: 0)
            }
            if let pick = library.findIndices(matching: "gotosleep_wakeup").randomElement() {
                animQueue.append(pick)
            }
        }

        let dayOfMonth = Calendar.current.component(.day, from: Date())
        if !greetedToday && dayOfMonth != lastGreetingDay && hour >= 6 && hour < 10 {
            greetedToday = true
            lastGreetingDay = dayOfMonth
            if let pick = library.findIndices(matching: "greeting_goodmorning").randomElement() {
                animQueue.insert(pick, at: 0)
            }
        }

        if newMood != mood {
            mood = newMood
            if animQueue.isEmpty {
                playNextAnimation()
            }
        }
    }

    private func updateVoice(now: Double) {
        if voiceResolveAtMs > 0 && now > voiceResolveAtMs {
            setVoicePhase(.idle)
        }
        let dt = Self.clamp(now - lastVoiceUpdateMs, 0, 80)
        lastVoiceUpdateMs = now

        let targetLevel = voicePhase == .listening ? voiceRawLevel : 0
        let tau = targetLevel > voiceLevel ? 45.0 : 190.0
        voiceLevel += (targetLevel - voiceLevel) * (1.0 - exp(-dt / tau))

        let activeTarget = voicePhase.isActive ? 1.0 : 0.0
        voicePhaseAmount += (activeTarget - voicePhaseAmount) * (1.0 - exp(-dt / (voicePhase.isActive ? 110.0 : 200.0)))
        if voicePhaseAmount < 0.005 { voicePhaseAmount = 0 }

        let morphTarget = voicePhase == .thinking ? 1.0 : 0.0
        let morphTau = morphTarget > thinkMorph ? 150.0 : 260.0
        thinkMorph += (morphTarget - thinkMorph) * (1.0 - exp(-dt / morphTau))
        if thinkMorph < 0.002 { thinkMorph = 0 }
    }

    private func updateBlink(now: Double) {
        if !isBlinking && now > nextBlinkAtMs {
            isBlinking = true
            blinkStartedAtMs = now
            blinkDurationMs = (isLowBattery || mood == .sleepy)
                ? 220 + Double.random(in: 0...110)
                : 140 + Double.random(in: 0...100)
            let doubleBlink = Double.random(in: 0...1) < 0.2
            nextBlinkAtMs = now + blinkDurationMs + (doubleBlink ? 200 + Double.random(in: 0...200) : 3000 + Double.random(in: 0...5000))
        }
        if isBlinking {
            let elapsed = now - blinkStartedAtMs
            let half = blinkDurationMs / 2.0
            if elapsed < half {
                blinkProgress = elapsed / half
            } else if elapsed < blinkDurationMs {
                blinkProgress = 1.0 - (elapsed - half) / half
            } else {
                blinkProgress = 0
                isBlinking = false
                blinkEndedAtMs = now
            }
        }
    }

    private func updateSaccade(now: Double) {
        if now > nextSaccadeAtMs {
            saccadeTargetX = Double.random(in: -1.5...1.5)
            saccadeTargetY = Double.random(in: -0.75...0.75)
            nextSaccadeAtMs = now + 800 + Double.random(in: 0...4000)
        }
        saccadeX += (saccadeTargetX - saccadeX) * 0.08
        saccadeY += (saccadeTargetY - saccadeY) * 0.08
    }

    private func updateGazeTracking(now: Double) {
        guard !isTyping else { return }
        if now > nextDistractionAtMs {
            isDistracted = Double.random(in: 0...1) < 0.25
            nextDistractionAtMs = now + (isDistracted ? 1500 : 4000 + Double.random(in: 0...4000))
        }
        if isDistracted {
            if !hasDistractionOffset {
                distractionOffsetX = Double.random(in: -20...20)
                distractionOffsetY = Double.random(in: -10...10)
                hasDistractionOffset = true
            }
            lookOffsetX += (distractionOffsetX - lookOffsetX) * 0.05
            lookOffsetY += (distractionOffsetY - lookOffsetY) * 0.05
        } else {
            hasDistractionOffset = false
            let targetX = (mouseX - 0.5) * 52.0
            let targetY = (0.5 - mouseY) * 18.0
            lookOffsetX += (targetX - lookOffsetX) * 0.055
            lookOffsetY += (targetY - lookOffsetY) * 0.055
            lookOffsetX += sin(now * 0.006) * 0.35
            lookOffsetY += cos(now * 0.007) * 0.28
        }
    }

    private func playBehaviorCategory(_ category: String, immediate: Bool = false) {
        let indices = AndyAnimationLibrary.behaviorAnimations[category] != nil
            ? library.resolveBehavior(category)
            : library.findIndices(matching: category)
        guard let pick = indices.randomElement() else { return }
        if immediate {
            animQueue.insert(pick, at: 0)
            playNextAnimation()
        } else {
            animQueue.append(pick)
            if animQueue.count == 1 {
                playNextAnimation()
            }
        }
    }

    private func chooseNextClipIndex() -> Int? {
        if isIdle {
            let sleepIndices = library.resolveBehavior("sleeping")
            if let pick = sleepIndices.randomElement() { return pick }
        }
        if isOffline && Double.random(in: 0...1) < 0.45 {
            let exploreIndices = library.resolveBehavior("explore")
            if let pick = exploreIndices.randomElement() { return pick }
        }
        let weights = Self.moodBehaviors[mood] ?? Self.moodBehaviors[.idle]!
        let behavior = weightedPick(weights)
        var indices = library.resolveBehavior(behavior)
        if indices.isEmpty {
            indices = library.findIndices(matching: "keepalive")
        }
        guard !indices.isEmpty else { return library.items.isEmpty ? nil : Int.random(in: 0..<library.items.count) }
        var pick = indices.randomElement()!
        if indices.count > 1 {
            var tries = 0
            while pick == currentClipIndex && tries < 5 {
                pick = indices.randomElement()!
                tries += 1
            }
        }
        return pick
    }

    private func playNextAnimation() {
        if !animQueue.isEmpty {
            let next = animQueue.removeFirst()
            loadClip(at: next)
            return
        }
        if let idx = chooseNextClipIndex() {
            loadClip(at: idx)
        }
    }

    private func loadClip(at index: Int) {
        let now = Self.nowMs()
        currentClip = library.clip(at: index)
        currentClipIndex = index
        clipStartedAtMs = now
        scheduleNextAnimation(now: now)
    }

    private func scheduleNextAnimation(now: Double) {
        let isSlow = (mood == .sleeping || mood == .sleepy)
        let baseDwell = isSlow ? 4000.0 : 800.0
        let randDwell = isSlow ? 6000.0 : 2500.0
        let animPart = min(currentClip.durationMs, isSlow ? 10000.0 : 5000.0)
        let canSettle = !isSlow && animQueue.isEmpty && !portholeOffCentre &&
            (mood == .idle || mood == .content || mood == .bored)
        let settle = (canSettle && Double.random(in: 0...1) < 0.35) ? 18000.0 + Double.random(in: 0...40000.0) : 0.0
        nextAnimationAtMs = now + animPart + baseDwell + Double.random(in: 0...randDwell) + settle
    }

    private func weightedPick(_ entries: [(String, Double)]) -> String {
        let total = entries.reduce(0.0) { $0 + $1.1 }
        var roll = Double.random(in: 0..<max(total, 0.0001))
        for (key, weight) in entries {
            roll -= weight
            if roll <= 0 { return key }
        }
        return entries.last?.0 ?? "idle_blink"
    }

    private func sampleFaceTrack(_ track: [AndyFaceKeyFrame], at timeMs: Double) -> AndyFaceKeyFrame {
        guard let first = track.first else { return .neutral }
        var prev = first
        var next = track.last ?? first
        for frame in track {
            if frame.triggerTimeMs <= timeMs { prev = frame }
            if frame.triggerTimeMs >= timeMs { next = frame; break }
        }
        if prev.triggerTimeMs == next.triggerTimeMs { return prev }
        let span = max(1.0, next.triggerTimeMs - prev.triggerTimeMs)
        let t = Self.ease(Self.clamp((timeMs - prev.triggerTimeMs) / span, 0, 1))
        return Self.interpolateFrame(prev, next, amount: t)
    }

    private func smoothFaceFrame(_ target: AndyFaceKeyFrame, now: Double) -> AndyFaceKeyFrame {
        guard let current = smoothedFace else {
            smoothedFace = target
            lastFaceSmoothMs = now
            return target
        }
        let dt = Self.clamp(now - lastFaceSmoothMs, 0, 80)
        lastFaceSmoothMs = now
        let amount = 1.0 - exp(-dt / 72.0)
        let next = Self.interpolateFrame(current, target, amount: amount)
        smoothedFace = next
        return next
    }

    private func normalizeFaceForDisplay(_ face: AndyFaceKeyFrame) -> AndyFaceKeyFrame {
        var safe = face
        let minGap = 13.5
        let lx = safe.leftEye[0]
        let rx = safe.rightEye[0]
        if lx - rx < minGap {
            let center = (lx + rx) / 2.0
            safe.leftEye[0] = center + minGap / 2.0
            safe.rightEye[0] = center - minGap / 2.0
        }
        safe.leftEye[2] = Self.clamp(safe.leftEye[2], 0.55, 1.55)
        safe.leftEye[3] = Self.clamp(safe.leftEye[3], 0.55, 1.55)
        safe.rightEye[2] = Self.clamp(safe.rightEye[2], 0.55, 1.55)
        safe.rightEye[3] = Self.clamp(safe.rightEye[3], 0.55, 1.55)
        return safe
    }

    private func getBreathScale(now: Double) -> Double {
        1.0 + sin(now / 1800.0) * 0.008 + sin(now / 4200.0) * 0.004
    }

    nonisolated static func eyeHalfWidth(_ params: [Double]) -> Double {
        let sx = clamp(params.count > 2 ? params[2] : 1, 0.28, 2.2)
        let sy = clamp(params.count > 3 ? params[3] : 1, 0.1, 1.8)
        let eyeScale = clamp(1.0 + ((sx + sy) / 2.0 - 1.0) * 0.42, 0.82, 1.36)
        return 14.0 * eyeScale
    }

    nonisolated static func eyeHiddenFraction(centre: Double, half: Double) -> Double {
        guard half > 0 else { return 0 }
        return clamp((abs(centre) + half - wingVisibleHalfWidth) / (2.0 * half), 0, 1)
    }

    nonisolated static func clampLookXToPorthole(safe: AndyFaceKeyFrame, lookX: Double, faceX: Double, xFactor: Double) -> Double {
        guard xFactor > 0 else { return lookX }
        var lo = -Double.infinity
        var hi = Double.infinity
        for params in [safe.leftEye, safe.rightEye] {
            let half = eyeHalfWidth(params) * xFactor
            let limit = wingVisibleHalfWidth - half * (1.0 - 2.0 * maxGazeEyeClip)
            let eyeX = params[0] * 3.0
            lo = max(lo, (-limit - faceX) / xFactor - eyeX)
            hi = min(hi, (limit - faceX) / xFactor - eyeX)
        }
        if lo > hi { return 0 }
        return clamp(lookX, lo, hi)
    }

    private func updatePortholeGuard(
        safe: AndyFaceKeyFrame, now: Double, baseX: Double, xFactor: Double, lookX: Double, isWing: Bool, dtScale: Double
    ) -> Double {
        guard isWing else {
            portholeOutSinceMs = 0
            portholeBackSinceMs = 0
            portholeAmount = 0
            portholeOffCentre = false
            return 0
        }

        var lost = false
        for params in [safe.leftEye, safe.rightEye] {
            let centre = baseX + (lookX + params[0] * 3.0 + saccadeX) * xFactor
            let half = Self.eyeHalfWidth(params) * xFactor
            if Self.eyeHiddenFraction(centre: centre, half: half) > Self.guardEyeClip {
                lost = true
                break
            }
        }

        if lost {
            portholeBackSinceMs = 0
            if portholeOutSinceMs == 0 { portholeOutSinceMs = now }
        } else {
            if portholeBackSinceMs == 0 { portholeBackSinceMs = now }
            if now - portholeBackSinceMs > Self.portholeReleaseMs {
                portholeOutSinceMs = 0
            }
        }
        portholeOffCentre = (portholeOutSinceMs != 0)

        let overdue = portholeOutSinceMs > 0 && (now - portholeOutSinceMs) > Self.portholeGraceMs
        let easeRate = 1.0 - pow(1.0 - (overdue ? 0.16 : 0.045), dtScale)
        portholeAmount += ((overdue ? 1.0 : 0.0) - portholeAmount) * easeRate
        if portholeAmount < 0.001 { portholeAmount = 0 }
        return portholeAmount
    }

    nonisolated static func applyPortholeFraming(
        to face: inout AndyFaceKeyFrame,
        guardAmount: Double,
        baseX: Double,
        xFactor: Double,
        lookX: Double,
        saccadeX: Double
    ) {
        if guardAmount > 0 {
            let mid = (face.leftEye[0] + face.rightEye[0]) / 2.0
            let pull = mid * guardAmount
            face.leftEye[0] -= pull
            face.rightEye[0] -= pull
            face.faceCenterX = lerp(face.faceCenterX, 0, guardAmount)
        }

        guard xFactor > 0 else { return }

        let halfL = eyeHalfWidth(face.leftEye) * xFactor
        let halfR = eyeHalfWidth(face.rightEye) * xFactor
        let limitL = wingVisibleHalfWidth - halfL * (1.0 - 2.0 * maxHardEyeClip)
        let limitR = wingVisibleHalfWidth - halfR * (1.0 - 2.0 * maxHardEyeClip)
        let maxHardGap = max(0.0, (limitL + limitR) / (3.0 * xFactor))
        let maxSoftGap = max(0.0, 2.0 * (wingVisibleHalfWidth - max(halfL, halfR) * (1.0 - 2.0 * maxGazeEyeClip)) / (3.0 * xFactor))

        let gap = face.leftEye[0] - face.rightEye[0]
        if gap > maxSoftGap {
            let target = min(lerp(gap, maxSoftGap, max(guardAmount, 0.75)), maxHardGap)
            let centre = (face.leftEye[0] + face.rightEye[0]) / 2.0
            face.leftEye[0] = centre + target / 2.0
            face.rightEye[0] = centre - target / 2.0
        }

        let leftCentre = baseX + (lookX + face.leftEye[0] * 3.0 + saccadeX) * xFactor
        let rightCentre = baseX + (lookX + face.rightEye[0] * 3.0 + saccadeX) * xFactor

        let minShift = max(-limitL - leftCentre, -limitR - rightCentre)
        let maxShift = min(limitL - leftCentre, limitR - rightCentre)
        var shiftPx = 0.0
        if minShift > 0 {
            shiftPx = minShift
        } else if maxShift < 0 {
            shiftPx = maxShift
        }
        if shiftPx != 0 {
            let shiftEyeUnits = shiftPx / (3.0 * xFactor)
            face.leftEye[0] += shiftEyeUnits
            face.rightEye[0] += shiftEyeUnits
        }
    }

    nonisolated static func clamp(_ v: Double, _ minVal: Double, _ maxVal: Double) -> Double {
        min(maxVal, max(minVal, v))
    }

    nonisolated static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    nonisolated static func ease(_ t: Double) -> Double {
        t * t * (3.0 - 2.0 * t)
    }

    nonisolated static func interpolateFrame(_ a: AndyFaceKeyFrame, _ b: AndyFaceKeyFrame, amount: Double) -> AndyFaceKeyFrame {
        let lCount = max(a.leftEye.count, b.leftEye.count)
        let rCount = max(a.rightEye.count, b.rightEye.count)
        var left = [Double](repeating: 0, count: lCount)
        var right = [Double](repeating: 0, count: rCount)
        for i in 0..<lCount {
            let av = i < a.leftEye.count ? a.leftEye[i] : 0
            let bv = i < b.leftEye.count ? b.leftEye[i] : av
            left[i] = lerp(av, bv, amount)
        }
        for i in 0..<rCount {
            let av = i < a.rightEye.count ? a.rightEye[i] : 0
            let bv = i < b.rightEye.count ? b.rightEye[i] : av
            right[i] = lerp(av, bv, amount)
        }
        return AndyFaceKeyFrame(
            triggerTimeMs: a.triggerTimeMs,
            durationTimeMs: a.durationTimeMs,
            leftEye: left,
            rightEye: right,
            faceCenterX: lerp(a.faceCenterX, b.faceCenterX, amount),
            faceCenterY: lerp(a.faceCenterY, b.faceCenterY, amount),
            faceScaleX: lerp(a.faceScaleX, b.faceScaleX, amount),
            faceScaleY: lerp(a.faceScaleY, b.faceScaleY, amount),
            faceAngle: lerp(a.faceAngle, b.faceAngle, amount)
        )
    }
}
