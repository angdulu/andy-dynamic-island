import AppKit
import QuartzCore
import SwiftUI

struct AndyNotchWebViewMenuActions {
    let isCollapsed: () -> Bool
    let reload: () -> Void
    let showInNotch: () -> Void
    let hideFromNotch: () -> Void
}

private final class AndyFaceLayer: CALayer {
    let mode: AndyViewMode
    var snapshot: AndyFrameSnapshot?

    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    private static let normalEyeGradient: CGGradient? = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0xB9 / 255.0, green: 1.0, blue: 1.0, alpha: 1.0),
            CGColor(red: 0x5F / 255.0, green: 0xFA / 255.0, blue: 0xFA / 255.0, alpha: 1.0),
            CGColor(red: 0x32 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0, alpha: 1.0),
            CGColor(red: 0x12 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 0.28, 0.78, 1.0]
    )

    private static let sleepyEyeGradient: CGGradient? = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0xB9 / 255.0, green: 1.0, blue: 1.0, alpha: 1.0),
            CGColor(red: 0x5C / 255.0, green: 0xE0 / 255.0, blue: 0xE0 / 255.0, alpha: 1.0),
            CGColor(red: 0x29 / 255.0, green: 0x82 / 255.0, blue: 0x82 / 255.0, alpha: 1.0),
            CGColor(red: 0x12 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 0.28, 0.78, 1.0]
    )

    private static let lowBatteryEyeGradient: CGGradient? = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1.0, green: 0xEC / 255.0, blue: 0xB8 / 255.0, alpha: 1.0),
            CGColor(red: 1.0, green: 0xC2 / 255.0, blue: 0x5E / 255.0, alpha: 1.0),
            CGColor(red: 0xD9 / 255.0, green: 0x88 / 255.0, blue: 0x29 / 255.0, alpha: 1.0),
            CGColor(red: 0xD9 / 255.0, green: 0x88 / 255.0, blue: 0x29 / 255.0, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 0.28, 0.78, 1.0]
    )

    private static let chargeEyeGradient: CGGradient? = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0xE8 / 255.0, green: 1.0, blue: 0xF4 / 255.0, alpha: 1.0),
            CGColor(red: 0x6A / 255.0, green: 1.0, blue: 0xC8 / 255.0, alpha: 1.0),
            CGColor(red: 0x2E / 255.0, green: 0xE5 / 255.0, blue: 0xA8 / 255.0, alpha: 1.0),
            CGColor(red: 0x2E / 255.0, green: 0xE5 / 255.0, blue: 0xA8 / 255.0, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 0.28, 0.78, 1.0]
    )

    // Subtle, tight halo gradients (no foggy rim spill)
    private static let haloGradient: CGGradient? = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0x12 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0, alpha: 0.26),
            CGColor(red: 0x12 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0, alpha: 0.08),
            CGColor(red: 0x12 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )

    private static let amberHaloGradient: CGGradient? = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1.0, green: 0xB8 / 255.0, blue: 0x45 / 255.0, alpha: 0.24),
            CGColor(red: 1.0, green: 0xB8 / 255.0, blue: 0x45 / 255.0, alpha: 0.07),
            CGColor(red: 1.0, green: 0xB8 / 255.0, blue: 0x45 / 255.0, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )

    private static let chargeHaloGradient: CGGradient? = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0x4C / 255.0, green: 1.0, blue: 0xB8 / 255.0, alpha: 0.34),
            CGColor(red: 0x4C / 255.0, green: 1.0, blue: 0xB8 / 255.0, alpha: 0.11),
            CGColor(red: 0x4C / 255.0, green: 1.0, blue: 0xB8 / 255.0, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )

    private static let loaderSlotX: [Double] = [-27.0, 0.0, 27.0]
    private static let loaderDotSize: Double = 19.0
    private static let loaderBounceH: Double = 8.5
    private static let loaderCycleMs: Double = 640.0

    init(mode: AndyViewMode) {
        self.mode = mode
        super.init()
        isOpaque = true
        backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        isGeometryFlipped = true
        drawsAsynchronously = true
        actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull()
        ]
    }

    override init(layer: Any) {
        if let other = layer as? AndyFaceLayer {
            self.mode = other.mode
            self.snapshot = other.snapshot
        } else {
            self.mode = .wing
        }
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(in ctx: CGContext) {
        let width = Double(bounds.width)
        let height = Double(bounds.height)
        guard width > 0, height > 0 else { return }

        ctx.saveGState()
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(bounds)

        guard let snap = snapshot else {
            ctx.restoreGState()
            return
        }

        if mode == .expanded {
            ctx.setFillColor(red: 0x12 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0, alpha: 0.018)
            var y: Double = 0
            while y < height {
                ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
                y += 4
            }
        }

        ctx.translateBy(x: width / 2.0, y: height / 2.0)

        let finalScale: Double
        if mode == .wing {
            let viewToVirtual = min(width, height) / AndyPetEngine.wingVirtualDiameter
            ctx.scaleBy(x: viewToVirtual, y: viewToVirtual)
            finalScale = AndyPetEngine.wingBaseScale * snap.breathScale
        } else {
            let baseScale = min(width / 123.0, height / 84.0)
            finalScale = baseScale * 1.15 * snap.breathScale
        }

        drawFace(ctx, snap: snap, finalScale: finalScale)
        ctx.restoreGState()
    }

    private func drawFace(_ ctx: CGContext, snap: AndyFrameSnapshot, finalScale: Double) {
        var safe = snap.face
        let morph = snap.thinkMorph
        let faceSX = AndyPetEngine.lerp(safe.faceScaleX, 1.0, morph)
        let faceSY = AndyPetEngine.lerp(safe.faceScaleY, 1.0, morph)
        let squash = AndyPetEngine.lerp(snap.squash, 1.0, morph)

        let rawFaceX = AndyPetEngine.lerp(safe.faceCenterX * 1.1, 0.0, morph) + snap.swayX * (1.0 - morph)
        let eyeXFactor = faceSX * finalScale * squash

        if mode == .wing && morph < 0.99 {
            AndyPetEngine.applyPortholeFraming(
                to: &safe,
                guardAmount: snap.portholeGuardAmount,
                baseX: rawFaceX,
                xFactor: eyeXFactor,
                lookX: snap.lookX,
                saccadeX: snap.saccadeX
            )
        }

        ctx.saveGState()
        let tx = AndyPetEngine.lerp(safe.faceCenterX * 1.1, 0.0, morph) + snap.swayX * (1.0 - morph)
        let ty = AndyPetEngine.lerp(safe.faceCenterY * 0.78, 0.0, morph)
            + snap.swayY * (1.0 - morph)
            + snap.returnDropOffsetY * (1.0 - morph)
        ctx.translateBy(x: tx, y: ty)

        let angle = AndyPetEngine.clamp(AndyPetEngine.lerp(safe.faceAngle, 0.0, morph) + snap.tilt, -0.24, 0.24)
        ctx.rotate(by: angle)
        ctx.scaleBy(x: faceSX * finalScale * squash, y: faceSY * finalScale / sqrt(max(0.1, squash)))
        ctx.translateBy(x: snap.lookX, y: snap.lookY)

        drawEye(ctx, params: safe.leftEye, isLeft: true, snap: snap)
        drawEye(ctx, params: safe.rightEye, isLeft: false, snap: snap)
        drawLoaderMiddleDot(ctx, snap: snap)

        if morph < 0.15 {
            if snap.specialEffect == .chargeBurst {
                drawChargeSparks(ctx, progress: snap.effectProgress)
            }
            if snap.isHot {
                drawSweatDrops(ctx, nowMs: snap.nowMs)
            }
            if snap.mood == .sleeping && !snap.voicePhase.isActive {
                drawSleepZzz(ctx, nowMs: snap.nowMs)
            }
            if snap.isOffline && !snap.voicePhase.isActive && snap.mood != .sleeping {
                drawOfflineAccent(ctx, nowMs: snap.nowMs)
            }
            if snap.isLowBattery && mode == .expanded && !snap.voicePhase.isActive {
                drawLowBatteryBadge(ctx, nowMs: snap.nowMs)
            }
        }

        ctx.restoreGState()
    }

    private func drawChargeSparks(_ ctx: CGContext, progress: Double) {
        let fade = sin(min(1.0, progress * 1.4) * .pi) * (1.0 - progress * 0.35)
        guard fade > 0.02 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(red: 0x7E / 255.0, green: 1.0, blue: 0xD2 / 255.0, alpha: fade * 0.95)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)

        let angles: [Double] = [-2.55, -1.9, -1.25, -0.6, 0.55, 2.55]
        for (idx, a) in angles.enumerated() {
            let phase = AndyPetEngine.clamp(progress * 1.3 - Double(idx % 3) * 0.12, 0, 1)
            guard phase > 0 && phase < 1 else { continue }
            let r1 = 22.0 + phase * 14.0
            let r2 = r1 + (1.0 - phase) * 6.5
            ctx.move(to: CGPoint(x: cos(a) * r1, y: sin(a) * r1))
            ctx.addLine(to: CGPoint(x: cos(a) * r2, y: sin(a) * r2))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawSweatDrops(_ ctx: CGContext, nowMs: Double) {
        let drops: [(x: Double, offset: Double, scale: Double)] = [
            (28.0, 0.0, 1.0),
            (-27.0, 520.0, 0.8)
        ]
        ctx.saveGState()
        for d in drops {
            let p = (nowMs + d.offset).truncatingRemainder(dividingBy: 1100.0) / 1100.0
            let alpha = sin(p * .pi) * 0.88
            let y = -16.0 + p * 18.0
            let s = 3.2 * d.scale
            ctx.saveGState()
            ctx.translateBy(x: d.x, y: y)
            ctx.setFillColor(red: 0x7A / 255.0, green: 0xFC / 255.0, blue: 1.0, alpha: alpha)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: -s * 1.35))
            ctx.addQuadCurve(to: CGPoint(x: s, y: s * 0.4), control: CGPoint(x: s * 1.05, y: -s * 0.25))
            ctx.addArc(center: CGPoint(x: 0, y: s * 0.4), radius: s, startAngle: 0, endAngle: .pi, clockwise: false)
            ctx.addQuadCurve(to: CGPoint(x: 0, y: -s * 1.35), control: CGPoint(x: -s * 1.05, y: -s * 0.25))
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    private func drawSleepZzz(_ ctx: CGContext, nowMs: Double) {
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for i in 0..<2 {
            let cycle = 2400.0
            let p = (nowMs + Double(i) * 1200.0).truncatingRemainder(dividingBy: cycle) / cycle
            let alpha = sin(p * .pi) * 0.72
            guard alpha > 0.04 else { continue }
            let x = 21.0 + p * 7.0 + sin(p * .pi * 2.0) * 1.6
            let y = -8.0 - p * 15.0
            let sz = (3.4 + p * 2.2) * (i == 0 ? 1.0 : 0.82)

            ctx.setStrokeColor(red: 0x5F / 255.0, green: 0xFA / 255.0, blue: 0xFA / 255.0, alpha: alpha)
            ctx.setLineWidth(1.3)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x - sz, y: y - sz))
            ctx.addLine(to: CGPoint(x: x + sz, y: y - sz))
            ctx.addLine(to: CGPoint(x: x - sz, y: y + sz))
            ctx.addLine(to: CGPoint(x: x + sz, y: y + sz))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawOfflineAccent(_ ctx: CGContext, nowMs: Double) {
        let pulse = (sin(nowMs / 750.0) + 1.0) * 0.5
        let alpha = 0.25 + pulse * 0.55
        ctx.saveGState()
        ctx.translateBy(x: 24.0, y: -19.0 - pulse * 1.5)
        ctx.setStrokeColor(red: 0x5F / 255.0, green: 0xFA / 255.0, blue: 0xFA / 255.0, alpha: alpha)
        ctx.setFillColor(red: 0x5F / 255.0, green: 0xFA / 255.0, blue: 0xFA / 255.0, alpha: alpha)
        ctx.setLineWidth(1.4)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: 0, y: -2.2), radius: 2.4, startAngle: .pi * 1.1, endAngle: .pi * 0.25, clockwise: false)
        ctx.addLine(to: CGPoint(x: 0, y: 1.5))
        ctx.strokePath()
        ctx.fillEllipse(in: CGRect(x: -0.9, y: 3.1, width: 1.8, height: 1.8))
        ctx.restoreGState()
    }

    private func drawLowBatteryBadge(_ ctx: CGContext, nowMs: Double) {
        let pulse = 0.45 + 0.4 * ((sin(nowMs / 800.0) + 1.0) * 0.5)
        ctx.saveGState()
        ctx.translateBy(x: 42.0, y: -16.0)
        ctx.setStrokeColor(red: 1.0, green: 0xB8 / 255.0, blue: 0x45 / 255.0, alpha: pulse)
        ctx.setFillColor(red: 1.0, green: 0xB8 / 255.0, blue: 0x45 / 255.0, alpha: pulse)
        ctx.setLineWidth(1.2)
        ctx.stroke(CGRect(x: -6, y: -3.5, width: 11, height: 7))
        ctx.fill(CGRect(x: 5.5, y: -1.6, width: 1.6, height: 3.2))
        ctx.fill(CGRect(x: -4.2, y: -1.8, width: 2.5, height: 3.6))
        ctx.restoreGState()
    }

    private func loaderBounce(nowMs: Double, index: Int) -> Double {
        var phase = ((nowMs / Self.loaderCycleMs) - Double(index) * 0.17).truncatingRemainder(dividingBy: 1.0)
        if phase < 0 { phase += 1.0 }
        return -max(0.0, sin(phase * .pi * 2.0)) * Self.loaderBounceH
    }

    private func drawLoaderMiddleDot(_ ctx: CGContext, snap: AndyFrameSnapshot) {
        let morph = snap.thinkMorph
        guard morph >= 0.01 else { return }

        let size = Self.loaderDotSize * morph
        let y = loaderBounce(nowMs: snap.nowMs, index: 1) * morph
        let radius = size / 2.0

        ctx.saveGState()
        ctx.translateBy(x: Self.loaderSlotX[1], y: y)
        ctx.setAlpha(morph)

        if let halo = Self.haloGradient {
            ctx.drawRadialGradient(
                halo,
                startCenter: .zero, startRadius: radius * 0.55,
                endCenter: .zero, endRadius: radius * 1.35,
                options: []
            )
        }

        if let grad = Self.normalEyeGradient {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: -radius, y: -radius, width: size, height: size))
            ctx.clip()
            ctx.drawRadialGradient(
                grad,
                startCenter: .zero, startRadius: 1.5,
                endCenter: .zero, endRadius: size * 0.75,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    private func drawEye(_ ctx: CGContext, params: [Double], isLeft: Bool, snap: AndyFrameSnapshot) {
        let p: (Int, Double) -> Double = { idx, def in idx < params.count ? params[idx] : def }

        let centerX = p(0, 0) * 3.0 + snap.saccadeX
        var centerY = p(1, 0) * 2.25 + snap.saccadeY
        let scaleX = AndyPetEngine.clamp(p(2, 1), 0.28, 2.2)
        let scaleY = AndyPetEngine.clamp(p(3, 1), 0.1, 1.8)
        let rawScale = (scaleX + scaleY) / 2.0
        let eyeScale = AndyPetEngine.clamp(1.0 + (rawScale - 1.0) * 0.42, 0.82, 1.36)
        var angle = AndyPetEngine.clamp(p(4, 0), -14, 14) * .pi / 180.0

        var upperLid = AndyPetEngine.clamp(p(13, 0), 0, 1)
        var upperLidAngle = p(14, 0) * .pi / 180.0
        var lowerLid = AndyPetEngine.clamp(p(16, 0), 0, 1)
        let lowerLidAngle = p(17, 0) * .pi / 180.0
        let glow = AndyPetEngine.clamp(p(21, 0) + p(24, 0) + 0.35, 0.15, 1.2)
        let hotspotX = AndyPetEngine.clamp(p(22, 0), -1, 1)
        let hotspotY = AndyPetEngine.clamp(p(23, 0), -1, 1)

        upperLid = max(upperLid, snap.blinkProgress * 0.96)

        var width = 28.0 * eyeScale
        var height = 28.0 * eyeScale
        let alivePulse = sin(snap.nowMs / 680.0 + (isLeft ? 0.0 : 0.35)) * 0.018
        width *= 1.0 + alivePulse - snap.blinkRebound * 0.4
        height *= 1.0 - alivePulse * 0.55 + snap.blinkRebound

        switch snap.mood {
        case .happy, .content, .affectionate:
            height *= 0.86; width *= 1.05
        case .sleeping, .sleepy:
            height *= 0.38; centerY += 6.0
        case .excited:
            width *= 1.08; height *= 1.04
        case .sad:
            height *= 0.90
        default:
            break
        }

        // Sustained typing focus squint
        if snap.typingFocusAmount > 0.01 {
            let f = snap.typingFocusAmount
            height *= AndyPetEngine.lerp(1.0, 0.78, f)
            upperLid = max(upperLid, 0.16 * f)
            lowerLid = max(lowerLid, 0.12 * f)
        }

        if snap.isLowBattery && !snap.voicePhase.isActive && snap.mood != .sleeping {
            upperLid = max(upperLid, 0.28)
            height *= 0.88
        } else if snap.isLateNight && !snap.voicePhase.isActive && snap.mood == .idle {
            upperLid = max(upperLid, 0.16)
        }

        var extraGlow = 0.0
        var curvedSmile = snap.happySmileAmount
        switch snap.specialEffect {
        case .chargeBurst:
            let s = sin(min(1.0, snap.effectProgress * 1.5) * .pi)
            width *= 1.0 + 0.08 * s
            height *= 1.0 + 0.06 * s
            extraGlow = 3.5 * s
            curvedSmile = max(curvedSmile, s * 0.8)
        case .grumpyReturn:
            let s = sin(snap.effectProgress * .pi)
            upperLid = max(upperLid, 0.32 * s)
            upperLidAngle += (isLeft ? -0.22 : 0.22) * s
            curvedSmile = 0
        case .startledWake:
            let s = sin(min(1.0, snap.effectProgress * 2.2) * .pi)
            width *= 1.0 + 0.14 * s
            height *= 1.0 + 0.16 * s
            upperLid *= (1.0 - s)
            curvedSmile = 0
        case .dizzy:
            let s = 1.0 - snap.effectProgress
            let asym = sin(snap.effectProgress * .pi * 6.0 + (isLeft ? 0 : .pi)) * 0.14 * s
            height *= 1.0 + asym
            angle += asym * 0.8
            curvedSmile = 0
        case .happyReturn:
            let s = sin(snap.effectProgress * .pi)
            width *= 1.0 + 0.06 * s
            curvedSmile = max(curvedSmile, s)
        case .winkLeft:
            let s = sin(snap.effectProgress * .pi)
            if isLeft {
                // Smoothly close winking eye into a cheeky curved wink
                upperLid = max(upperLid, 0.82 * s)
                lowerLid = max(lowerLid, 0.12 * s)
                height *= AndyPetEngine.lerp(1.0, 0.85, s)
            } else {
                height *= 1.0 + 0.05 * s
            }
        case .winkRight:
            let s = sin(snap.effectProgress * .pi)
            if !isLeft {
                upperLid = max(upperLid, 0.82 * s)
                lowerLid = max(lowerLid, 0.12 * s)
                height *= AndyPetEngine.lerp(1.0, 0.85, s)
            } else {
                height *= 1.0 + 0.05 * s
            }
        case .yawn:
            // Slow squeeze-shut yawn peak, then relieved wide blink
            let p = snap.effectProgress
            let squeeze = p < 0.72 ? sin((p / 0.72) * .pi) : 0.0
            let openRelief = p >= 0.72 ? sin(((p - 0.72) / 0.28) * .pi) : 0.0
            upperLid = max(upperLid, 0.62 * squeeze)
            lowerLid = max(lowerLid, 0.22 * squeeze)
            width *= 1.0 + 0.07 * squeeze
            height *= (1.0 - 0.18 * squeeze + 0.08 * openRelief)
            curvedSmile = 0
        case .appSwitchPerk:
            let s = sin(snap.effectProgress * .pi)
            width *= 1.0 + 0.06 * s
            height *= 1.0 + 0.11 * s
            upperLid *= (1.0 - 0.6 * s)
        case .none:
            break
        }

        let vAmt = snap.voicePhaseAmount
        var voiceGlow = 0.0
        switch snap.voicePhase {
        case .arming:
            height *= AndyPetEngine.lerp(1.0, 0.62, vAmt)
            lowerLid = max(lowerLid, 0.18 * vAmt)
            voiceGlow = 2.5 * vAmt
        case .listening:
            let lvl = snap.voiceLevel
            height *= AndyPetEngine.lerp(1.0, 0.72 + lvl * 0.40, vAmt)
            width *= AndyPetEngine.lerp(1.0, 1.02 + lvl * 0.06, vAmt)
            lowerLid = max(lowerLid, (0.22 - lvl * 0.20) * vAmt)
            voiceGlow = (1.5 + lvl * 5.5) * vAmt
        case .success:
            height *= AndyPetEngine.lerp(1.0, 0.80, vAmt)
            width *= AndyPetEngine.lerp(1.0, 1.08, vAmt)
            voiceGlow = 5.0 * vAmt
        case .error:
            height *= AndyPetEngine.lerp(1.0, 0.55, vAmt)
            upperLid = max(upperLid, 0.42 * vAmt)
            voiceGlow = 1.2 * vAmt
        case .thinking, .idle:
            break
        }

        let morph = snap.thinkMorph
        var bounceY = 0.0
        var renderCenterX = centerX
        if morph > 0 {
            let dotIndex = isLeft ? 2 : 0
            renderCenterX = AndyPetEngine.lerp(centerX, Self.loaderSlotX[dotIndex], morph)
            centerY = AndyPetEngine.lerp(centerY, 0.0, morph)
            width = AndyPetEngine.lerp(width, Self.loaderDotSize, morph)
            height = AndyPetEngine.lerp(height, Self.loaderDotSize, morph)
            upperLid *= (1.0 - morph)
            lowerLid *= (1.0 - morph)
            curvedSmile *= (1.0 - morph)
            bounceY = loaderBounce(nowMs: snap.nowMs, index: dotIndex) * morph
            voiceGlow = max(voiceGlow, 2.2 * morph)
        }

        ctx.saveGState()
        let floatY = sin(snap.nowMs / 1100.0 + (isLeft ? 0.4 : 0.9)) * 0.28
        ctx.translateBy(x: renderCenterX, y: centerY + floatY * (1.0 - morph) + bounceY)
        ctx.rotate(by: angle * (1.0 - morph))

        let useChargePalette = (snap.specialEffect == .chargeBurst && !snap.voicePhase.isActive)
        let useLowBatPalette = (snap.isLowBattery && !useChargePalette && !snap.voicePhase.isActive)
        let isSleepy = (snap.mood == .sleeping || snap.mood == .sleepy)

        let haloGrad: CGGradient? = useChargePalette
            ? Self.chargeHaloGradient
            : (useLowBatPalette ? Self.amberHaloGradient : Self.haloGradient)
        let eyeGrad: CGGradient? = useChargePalette
            ? Self.chargeEyeGradient
            : (useLowBatPalette ? Self.lowBatteryEyeGradient : (isSleepy ? Self.sleepyEyeGradient : Self.normalEyeGradient))

        // Compute the actually visible open band of the eye so the glow hugs ONLY the lit area
        let topOpenY = -height / 2.0 + height * AndyPetEngine.clamp(upperLid, 0, 1)
        let effectiveLower = max(lowerLid, curvedSmile * 0.26)
        let bottomOpenY = height / 2.0 - height * AndyPetEngine.clamp(effectiveLower, 0, 1)
        let visibleHeight = max(0.0, bottomOpenY - topOpenY)
        let openness = AndyPetEngine.clamp(visibleHeight / max(1.0, height), 0, 1)
        let visibleCenterY = (topOpenY + bottomOpenY) / 2.0

        // 1) Draw soft glow halo centered strictly on the open lit band (zero bleed behind closed lids!)
        if let halo = haloGrad, openness > 0.04 {
            let glowBoost = 1.0 + min(0.45, (glow * 0.10 + snap.pulse * 0.06 + (voiceGlow + extraGlow) * 0.05))
            let haloHalfW = (width * 0.58) * glowBoost
            let haloHalfH = max(visibleHeight * 0.62, 4.5) * glowBoost
            ctx.saveGState()
            ctx.setAlpha(min(1.0, openness * 1.35))
            ctx.translateBy(x: 0, y: visibleCenterY)
            ctx.scaleBy(x: haloHalfW, y: haloHalfH)
            ctx.drawRadialGradient(
                halo,
                startCenter: .zero, startRadius: 0.35,
                endCenter: .zero, endRadius: 1.0,
                options: []
            )
            ctx.restoreGState()
        }

        // 2) Fill the eye shape with radial gradient
        let eyePath = makeEyePath(width: width, height: height, params: params, roundness: morph)
        if let grad = eyeGrad {
            ctx.saveGState()
            ctx.addPath(eyePath)
            ctx.clip()
            ctx.drawRadialGradient(
                grad,
                startCenter: CGPoint(x: hotspotX * width * 0.25, y: hotspotY * height * 0.25),
                startRadius: 2.0,
                endCenter: .zero,
                endRadius: width * 0.78,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            ctx.restoreGState()
        }

        // 3) Draw solid black eyelids UNCLIPPED over both the eye and halo so zero glow or ghost border ever leaks!
        drawLid(ctx, width: width, height: height, amount: upperLid, angle: upperLidAngle, isTop: true)
        drawLid(ctx, width: width, height: height, amount: lowerLid, angle: lowerLidAngle, isTop: false)

        // 4) Optional curved lower-lid smile arc (반달 눈웃음) for happy/affectionate/petting states
        if curvedSmile > 0.05 && openness > 0.20 {
            drawHappySmileArc(ctx, width: width, height: height, amount: curvedSmile)
        }

        ctx.restoreGState()
    }

    private func drawHappySmileArc(_ ctx: CGContext, width: Double, height: Double, amount: Double) {
        // Soft black oval rising cleanly from the bottom center to carve a crescent-smile eye
        let rise = height * 0.34 * AndyPetEngine.clamp(amount, 0, 1)
        let rx = width * 0.56
        let ry = height * 0.44
        let cy = height / 2.0 + ry - rise
        ctx.saveGState()
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: -rx, y: cy - ry, width: rx * 2.0, height: ry * 2.0))
        ctx.restoreGState()
    }

    private func makeEyePath(width: Double, height: Double, params: [Double], roundness: Double) -> CGPath {
        let p: (Int) -> Double = { idx in AndyPetEngine.clamp(idx < params.count ? params[idx] : 0.6, 0, 1) }
        let liX = p(5), liY = p(6), uiX = p(7), uiY = p(8)
        let uoX = p(9), uoY = p(10), loX = p(11), loY = p(12)

        var tl = 4.0 + max(uiX, uiY) * 9.0
        var tr = 4.0 + max(uoX, uoY) * 9.0
        var br = 4.0 + max(loX, loY) * 9.0
        var bl = 4.0 + max(liX, liY) * 9.0

        let maxR = min(width, height) / 2.0
        if roundness > 0 {
            tl = AndyPetEngine.lerp(tl, maxR, roundness)
            tr = AndyPetEngine.lerp(tr, maxR, roundness)
            br = AndyPetEngine.lerp(br, maxR, roundness)
            bl = AndyPetEngine.lerp(bl, maxR, roundness)
        }
        tl = min(tl, maxR); tr = min(tr, maxR); br = min(br, maxR); bl = min(bl, maxR)

        let x = -width / 2.0
        let y = -height / 2.0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x + tl, y: y))
        path.addLine(to: CGPoint(x: x + width - tr, y: y))
        path.addQuadCurve(to: CGPoint(x: x + width, y: y + tr), control: CGPoint(x: x + width, y: y))
        path.addLine(to: CGPoint(x: x + width, y: y + height - br))
        path.addQuadCurve(to: CGPoint(x: x + width - br, y: y + height), control: CGPoint(x: x + width, y: y + height))
        path.addLine(to: CGPoint(x: x + bl, y: y + height))
        path.addQuadCurve(to: CGPoint(x: x, y: y + height - bl), control: CGPoint(x: x, y: y + height))
        path.addLine(to: CGPoint(x: x, y: y + tl))
        path.addQuadCurve(to: CGPoint(x: x + tl, y: y), control: CGPoint(x: x, y: y))
        path.closeSubpath()
        return path
    }

    private func drawLid(_ ctx: CGContext, width: Double, height: Double, amount: Double, angle: Double, isTop: Bool) {
        guard amount > 0.01 else { return }
        let cover = height * AndyPetEngine.clamp(amount, 0, 1)
        ctx.saveGState()
        ctx.rotate(by: angle * 0.38)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        if isTop {
            ctx.fill(CGRect(x: -width * 1.6, y: -height / 2.0 - 22.0, width: width * 3.2, height: cover + 22.5))
        } else {
            ctx.fill(CGRect(x: -width * 1.6, y: height / 2.0 - cover - 0.5, width: width * 3.2, height: cover + 22.5))
        }
        ctx.restoreGState()
    }
}

final class AndyCanvasNSView: NSView {
    let viewID = UUID()
    let mode: AndyViewMode
    var menuActions: AndyNotchWebViewMenuActions?

    private let faceLayer: AndyFaceLayer
    private var dragOrigin: NSPoint?
    private var dragFired = false
    private var isAttached = false

    init(mode: AndyViewMode) {
        self.mode = mode
        self.faceLayer = AndyFaceLayer(mode: mode)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = true
        layer?.backgroundColor = NSColor.black.cgColor
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(faceLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        faceLayer.frame = bounds
        if let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor {
            faceLayer.contentsScale = scale
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor {
            faceLayer.contentsScale = scale
        }
        if window != nil && !isAttached {
            isAttached = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                AndyPetEngine.shared.attach(view: self, id: self.viewID, mode: self.mode)
            }
        } else if window == nil && isAttached {
            isAttached = false
            let id = viewID
            Task { @MainActor in
                AndyPetEngine.shared.detach(id: id)
            }
        }
    }

    deinit {
        if isAttached {
            let id = viewID
            Task { @MainActor in
                AndyPetEngine.shared.detach(id: id)
            }
        }
    }

    func updateFrame(_ snapshot: AndyFrameSnapshot, force: Bool) {
        faceLayer.snapshot = snapshot
        faceLayer.setNeedsDisplay()
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragFired = false
        Task { @MainActor in
            AndyPetEngine.shared.handleTap()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, !dragFired else { return }
        let current = convert(event.locationInWindow, from: nil)
        if hypot(current.x - origin.x, current.y - origin.y) > 14 {
            dragFired = true
            Task { @MainActor in
                AndyPetEngine.shared.handleDrag()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        dragFired = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menuActions else {
            super.rightMouseDown(with: event)
            return
        }
        let isCollapsed = menuActions.isCollapsed()
        let menu = NSMenu()

        let showItem = NSMenuItem(title: "Show Andy in Notch", action: #selector(showAndyInNotch), keyEquivalent: "")
        showItem.target = self
        showItem.isEnabled = isCollapsed
        menu.addItem(showItem)

        let hideItem = NSMenuItem(title: "Hide Andy from Notch", action: #selector(hideAndyFromNotch), keyEquivalent: "")
        hideItem.target = self
        hideItem.isEnabled = !isCollapsed
        menu.addItem(hideItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func showAndyInNotch() {
        DispatchQueue.main.async { [weak self] in
            self?.menuActions?.showInNotch()
        }
    }

    @objc private func hideAndyFromNotch() {
        DispatchQueue.main.async { [weak self] in
            self?.menuActions?.hideFromNotch()
        }
    }
}

struct AndyFaceView: NSViewRepresentable {
    let mode: AndyViewMode
    var menuActions: AndyNotchWebViewMenuActions? = nil

    func makeNSView(context: Context) -> AndyCanvasNSView {
        let view = AndyCanvasNSView(mode: mode)
        view.menuActions = menuActions
        return view
    }

    func updateNSView(_ nsView: AndyCanvasNSView, context: Context) {
        nsView.menuActions = menuActions
    }
}
