import Foundation

struct AndyAnimationIndexItem: Decodable, Sendable {
    let label: String
    let path: String
}

struct AndyFaceKeyFrame: Sendable {
    var triggerTimeMs: Double
    var durationTimeMs: Double
    var leftEye: [Double]
    var rightEye: [Double]
    var faceCenterX: Double
    var faceCenterY: Double
    var faceScaleX: Double
    var faceScaleY: Double
    var faceAngle: Double

    static let neutral: AndyFaceKeyFrame = {
        let baseEye: [Double] = [
            0, 0, 1, 1, 0,
            0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6,
            0, 0, 0, 0, 0, 0, 0, 0, 0.35, 0, 0, 0
        ]
        var left = baseEye
        left[0] = 8.0
        var right = baseEye
        right[0] = -8.0
        return AndyFaceKeyFrame(
            triggerTimeMs: 0,
            durationTimeMs: 1000,
            leftEye: left,
            rightEye: right,
            faceCenterX: 0,
            faceCenterY: 0,
            faceScaleX: 1,
            faceScaleY: 1,
            faceAngle: 0
        )
    }()
}

struct AndyAnimationClip: Sendable {
    let name: String
    let faceFrames: [AndyFaceKeyFrame]
    let durationMs: Double

    static let fallback = AndyAnimationClip(
        name: "fallback_neutral",
        faceFrames: [.neutral],
        durationMs: 2000
    )
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

final class AndyAnimationLibrary {
    static let shared = AndyAnimationLibrary()

    static let behaviorAnimations: [String: [String]] = [
        // Tier 1: Core idle & awareness
        "idle_blink": ["keepalive_blink", "keepalive_eyes", "keepalive_eyesonly", "eyepose_blink", "neutral_eyes"],
        "idle_look": ["keepalive", "explorer_idle", "observing", "generic_look", "pause_idle"],
        "gazing": [
            "gazing_lookatfaces", "gazing_lookatsurface", "gazing_lookatvector", "gazing_turns",
            "explorer_lookaround", "explorer_center", "look_left", "look_right"
        ],
        "explore": [
            "explorer_huh", "explorer_scan", "explorer_planning", "exploring_test",
            "lookatdevice", "freeplay_reacttoface"
        ],
        "curious_observe": [
            "eyepose_curious", "eyepose_awe", "eyepose_captivated", "observing",
            "explorer_huh_close", "explorer_huh_far", "pounce_lookloop", "attention"
        ],
        // Eyepose micro-expressions
        "eyepose_micro": [
            "eyepose_angry", "eyepose_asleep", "eyepose_awe", "eyepose_blink", "eyepose_bliss",
            "eyepose_bothered", "eyepose_captivated", "eyepose_concerned", "eyepose_curious", "eyepose_default",
            "eyepose_determined", "eyepose_focused", "eyepose_frustrated", "eyepose_furious", "eyepose_happy",
            "eyepose_hurt", "eyepose_joy", "eyepose_sad", "eyepose_sad_down", "eyepose_scared",
            "eyepose_scrutinizing", "eyepose_shocked", "eyepose_squint", "eyepose_startled",
            "eyepose_suspicious", "eyepose_unsure", "eyepose_worried"
        ],
        // Tier 1: Reactions
        "cliff_react": [
            "reacttocliff_edge", "reacttocliff_stop", "reacttocliff_turnleft", "reacttocliff_turnright",
            "reacttocliff_faceplant", "reacttocliff_stuckonedge", "reacttocliff_turtleroll",
            "reacttocliff_sidestuck", "reacttocliff_reaction"
        ],
        "startled_react": ["rtmotion", "sudden_obstacle", "dizzy_reaction_medium", "dizzy_reaction_hard"],
        // Tier 2: Emotions & social
        "happy_react": [
            "eyepose_happy", "eyepose_joy", "eyepose_bliss", "eyecontact_smile", "greeting_happy",
            "pounce_success", "reacttoblock_success", "fistbump_success",
            "cubespinner_gamesuccess", "blackjack_victorwin", "cube_success"
        ],
        "excited_dance": [
            "dancebeat_eyebeat", "dancebeat_headnod", "dancebeat_headlift", "dancebeat_idle",
            "dancebeat_pivot", "dancebeat_scoot", "dancebeat_headliftbody",
            "cubespinner_anticroundsuccess", "cubespinner_anticgamesuccess"
        ],
        "content_calm": ["keepalive", "eyepose_happy", "eyecontact", "petting_blissloop"],
        "affectionate": [
            "petting_blissloop", "petting_bliss_getout", "freeplay_reacttoface_like",
            "freeplay_reacttoface_identified", "greeting_happy", "eyecontact_smile",
            "feedback_iloveyou"
        ],
        "bored": ["keepaway_bored", "explorer_idle", "slowpoke", "eyepose_sad_down", "pause_idle", "keepaway_idle"],
        "annoyed_react": [
            "eyepose_frustrated", "eyepose_scrutinizing", "feedback_badrobot",
            "feedback_bequiet", "feedback_shutup", "driving_upset", "communication_cantdothat"
        ],
        "frustrated_react": [
            "eyepose_frustrated", "avs_fail", "cubespinner_gamefail", "pounce_fail",
            "fistbump_fail", "cubedocking_fail", "cubespinner_sessionfail"
        ],
        "sad_react": [
            "eyepose_sad", "eyepose_sad_down", "eyepose_hurt", "eyepose_worried",
            "dizzy_reaction_soft", "feedback_apology", "feedback_meanwords"
        ],
        // Tier 2: Interaction responses
        "petting_response": [
            "petting_getin", "petting_lvl1", "petting_lvl2", "petting_lvl3",
            "petting_blissloop", "petting_bliss_getout"
        ],
        "greeting_hello": ["greeting_hello", "greeting_imhome", "greeting_happy", "onboarding_reacttoface_happy"],
        "feedback_positive": ["feedback_goodrobot", "feedback_iloveyou", "petting_blissloop"],
        "feedback_negative": ["feedback_badrobot", "feedback_bequiet", "feedback_shutup", "feedback_meanwords"],
        // Tier 2: Self-amusement
        "self_amuse": ["dancebeat", "cubespinner", "fistbump_idle", "blackjack_idle", "eyecolorreact", "spinner_tap"],
        "dance_full": ["dancebeat_getin", "dancebeat_eyebeat", "dancebeat_headnod", "dancebeat_pivot", "dancebeat_scoot", "dancebeat_getout"],
        "keepaway_game": [
            "keepaway_getready", "keepaway_idle", "keepaway_pounce", "keepaway_fakeout",
            "keepaway_hit_reaction", "keepaway_miss_reaction", "keepaway_wingame",
            "keepaway_losegame", "keepaway_backup", "keepaway_stopshort"
        ],
        "fistbump_game": ["fistbump_getin", "fistbump_idle", "fistbump_requestonce", "fistbump_success", "fistbump_fail"],
        // Tier 2: Referencing & face
        "face_react": [
            "freeplay_reacttoface_identified", "freeplay_reacttoface_like",
            "freeplay_reacttoface_sayname", "freeplay_reacttoface_longname",
            "reacttoface_unidentified", "movement_reacttoface"
        ],
        "referencing": [
            "referencing_curious", "referencing_happy", "referencing_scared",
            "referencing_unsure", "referencing_neutral"
        ],
        // Sleep/wake
        "sleepy": ["eyepose_asleep", "gotosleep_sleeping", "gotosleep_getin", "launch_sleeping", "rtsound_offcharger_asleep"],
        "sleeping": ["gotosleep_sleeping", "gotosleep_off", "gotosleep_sleeploop", "launch_sleeping"],
        "waking": ["gotosleep_getout", "gotosleep_wakeup", "power_offon", "onboarding_wakeup"],
        // Misc
        "hiking": ["hiking_driving", "hiking_observe", "hiking_lookaround"],
        "block_react": [
            "reacttoblock_react", "reacttoblock_success", "reacttoblock_frustrated",
            "reacttoblock_happydetermined", "reacttoblock_lifteffort",
            "reacttoblock_admire", "reacttoblock_dropfail", "reacttoblock_dropsuccess"
        ]
    ]

    private let rootURL: URL
    private(set) var items: [AndyAnimationIndexItem] = []
    private var lowerPaths: [String] = []
    private var fileMap: [String: URL] = [:]
    private var behaviorIndex: [String: [Int]] = [:]
    private var clipCache: [Int: AndyAnimationClip] = [:]
    private var isIndexed = false

    init(rootURL: URL = AndyNotchResources.rootURL) {
        self.rootURL = rootURL
    }

    func ensureLoaded() {
        guard !isIndexed else { return }
        isIndexed = true

        // Load animation-index.json
        let indexURL = rootURL
            .appendingPathComponent("macbook-pet")
            .appendingPathComponent("animation-index.json")

        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([AndyAnimationIndexItem].self, from: data) {
            var seen = Set<String>()
            var unique: [AndyAnimationIndexItem] = []
            unique.reserveCapacity(decoded.count)
            for item in decoded where seen.insert(item.path).inserted {
                unique.append(item)
            }
            items = unique
            lowerPaths = unique.map { $0.path.lowercased() }
        }

        // One-time filename -> URL lookup across assets/animations
        let animationsDir = rootURL
            .appendingPathComponent("assets")
            .appendingPathComponent("animations")
        if let enumerator = FileManager.default.enumerator(
            at: animationsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension.lowercased() == "json" {
                    fileMap[url.lastPathComponent] = url
                }
            }
        }

        // Pre-build behavior index once
        var index: [String: [Int]] = [:]
        for (behavior, tags) in Self.behaviorAnimations {
            var matches = Set<Int>()
            for tag in tags {
                let lower = tag.lowercased()
                for i in 0..<lowerPaths.count where lowerPaths[i].contains(lower) {
                    matches.insert(i)
                }
            }
            index[behavior] = Array(matches).sorted()
        }
        behaviorIndex = index
    }

    func resolveBehavior(_ behavior: String) -> [Int] {
        ensureLoaded()
        if let cached = behaviorIndex[behavior], !cached.isEmpty {
            return cached
        }
        if let fallback = behaviorIndex["idle_blink"], !fallback.isEmpty {
            return fallback
        }
        return []
    }

    func findIndices(matching substring: String) -> [Int] {
        ensureLoaded()
        let lower = substring.lowercased()
        var result: [Int] = []
        for i in 0..<lowerPaths.count where lowerPaths[i].contains(lower) {
            result.append(i)
        }
        return result
    }

    func clip(at index: Int) -> AndyAnimationClip {
        ensureLoaded()
        if let cached = clipCache[index] {
            return cached
        }
        guard items.indices.contains(index) else { return .fallback }
        let path = items[index].path
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let candidateURL: URL? = {
            let direct = rootURL.appendingPathComponent("macbook-pet").appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
            return fileMap[filename]
        }()

        guard let url = candidateURL,
              let data = try? Data(contentsOf: url),
              let parsed = parseClip(from: data) else {
            return .fallback
        }

        clipCache[index] = parsed
        return parsed
    }

    private func parseClip(from data: Data) -> AndyAnimationClip? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let (clipName, rawValue) = root.first,
              let rawFrames = rawValue as? [[String: Any]] else {
            return nil
        }

        var faceFrames: [AndyFaceKeyFrame] = []
        faceFrames.reserveCapacity(rawFrames.count)
        var maxEndMs: Double = 1000

        for dict in rawFrames {
            let trigger = (dict["triggerTime_ms"] as? NSNumber)?.doubleValue ?? 0
            let duration = (dict["durationTime_ms"] as? NSNumber)?.doubleValue ?? 0
            maxEndMs = max(maxEndMs, trigger + duration)

            guard (dict["Name"] as? String) == "ProceduralFaceKeyFrame" else { continue }
            guard let left = (dict["leftEye"] as? [NSNumber])?.map({ $0.doubleValue }),
                  let right = (dict["rightEye"] as? [NSNumber])?.map({ $0.doubleValue }),
                  left.count >= 18, right.count >= 18 else { continue }

            faceFrames.append(AndyFaceKeyFrame(
                triggerTimeMs: trigger,
                durationTimeMs: duration,
                leftEye: left,
                rightEye: right,
                faceCenterX: (dict["faceCenterX"] as? NSNumber)?.doubleValue ?? 0,
                faceCenterY: (dict["faceCenterY"] as? NSNumber)?.doubleValue ?? 0,
                faceScaleX: (dict["faceScaleX"] as? NSNumber)?.doubleValue ?? 1,
                faceScaleY: (dict["faceScaleY"] as? NSNumber)?.doubleValue ?? 1,
                faceAngle: (dict["faceAngle"] as? NSNumber)?.doubleValue ?? 0
            ))
        }

        faceFrames.sort { $0.triggerTimeMs < $1.triggerTimeMs }
        if faceFrames.isEmpty {
            return .fallback
        }
        return AndyAnimationClip(name: clipName, faceFrames: faceFrames, durationMs: maxEndMs)
    }
}
