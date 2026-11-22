import AppKit
import QuartzCore
import SwiftUI

struct AndyNotchWebViewMenuActions {
    let isCollapsed: () -> Bool
    let reload: () -> Void
    let showInNotch: () -> Void
    let hideFromNotch: () -> Void
}

/// Dedicated opaque CALayer for Andy rendering. Updating only this sublayer via
/// `setNeedsDisplay()` avoids `NSView.setNeedsDisplay`, which otherwise triggers
/// `NSViewSetNeedsUpdateVibrancy` and forces the entire SwiftUI notch window
/// backing store to re-upload on every frame.
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

    private static let haloGradient: CGGradient? = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0x12 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0, alpha: 0.42),
            CGColor(red: 0x12 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0, alpha: 0.14),
            CGColor(red: 0x12 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0, alpha: 0.0)
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

        // Expanded tab draws subtle CRT scanlines; skip in tiny wing where 1px lines are invisible sub-pixel noise
        if mode == .expanded {
            ctx.setFillColor(red: 0x12 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0, alpha: 0.022)
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
        let ty = AndyPetEngine.lerp(safe.faceCenterY * 0.78, 0.0, morph) + snap.swayY * (1.0 - morph)
        ctx.translateBy(x: tx, y: ty)

        let angle = AndyPetEngine.clamp(AndyPetEngine.lerp(safe.faceAngle, 0.0, morph) + snap.tilt, -0.2, 0.2)
        ctx.rotate(by: angle)
        ctx.scaleBy(x: faceSX * finalScale * squash, y: faceSY * finalScale / sqrt(max(0.1, squash)))
        ctx.translateBy(x: snap.lookX, y: snap.lookY)

        drawEye(ctx, params: safe.leftEye, isLeft: true, snap: snap)
        drawEye(ctx, params: safe.rightEye, isLeft: false, snap: snap)
        drawLoaderMiddleDot(ctx, snap: snap)

        if snap.isHot {
            ctx.setFillColor(red: 0x5F / 255.0, green: 0xFA / 255.0, blue: 0xFA / 255.0, alpha: 0.9)
            let sweat1 = snap.nowMs.truncatingRemainder(dividingBy: 1000.0) / 1000.0
            let sweat2 = (snap.nowMs + 500.0).truncatingRemainder(dividingBy: 1000.0) / 1000.0
            ctx.fill(CGRect(x: -20, y: -10 + sweat1 * 20, width: 2, height: 4))
            ctx.fill(CGRect(x: 20, y: -15 + sweat2 * 20, width: 2, height: 4))
        }

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
                startCenter: .zero, startRadius: radius * 0.6,
                endCenter: .zero, endRadius: radius * 1.45,
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

        ctx.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.setLineWidth(1.5)
        ctx.addEllipse(in: CGRect(x: -radius, y: -radius, width: size, height: size))
        ctx.strokePath()
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
        let angle = AndyPetEngine.clamp(p(4, 0), -14, 14) * .pi / 180.0

        var upperLid = AndyPetEngine.clamp(p(13, 0), 0, 1)
        let upperLidAngle = p(14, 0) * .pi / 180.0
        var lowerLid = AndyPetEngine.clamp(p(16, 0), 0, 1)
        let lowerLidAngle = p(17, 0) * .pi / 180.0
        let glow = AndyPetEngine.clamp(p(21, 0) + p(24, 0) + 0.35, 0.15, 1.2)
        let hotspotX = AndyPetEngine.clamp(p(22, 0), -1, 1)
        let hotspotY = AndyPetEngine.clamp(p(23, 0), -1, 1)

        upperLid = max(upperLid, snap.blinkProgress * 0.95)

        var width = 28.0 * eyeScale
        var height = 28.0 * eyeScale
        let alivePulse = sin(snap.nowMs / 680.0 + (isLeft ? 0.0 : 0.35)) * 0.018
        width *= 1.0 + alivePulse
        height *= 1.0 - alivePulse * 0.55

        switch snap.mood {
        case .happy, .content, .affectionate:
            height *= 0.84; width *= 1.05
        case .sleeping, .sleepy:
            height *= 0.38; centerY += 6.0
        case .excited:
            width *= 1.08; height *= 1.04
        case .sad:
            height *= 0.90
        default:
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
            bounceY = loaderBounce(nowMs: snap.nowMs, index: dotIndex) * morph
            voiceGlow = max(voiceGlow, 2.2 * morph)
        }

        ctx.saveGState()
        let floatY = sin(snap.nowMs / 1100.0 + (isLeft ? 0.4 : 0.9)) * 0.28
        ctx.translateBy(x: renderCenterX, y: centerY + floatY * (1.0 - morph) + bounceY)
        ctx.rotate(by: angle * (1.0 - morph))

        if let halo = Self.haloGradient {
            let glowBoost = 1.0 + min(0.55, (glow * 0.14 + snap.pulse * 0.08 + voiceGlow * 0.06))
            let haloRadius = max(width, height) * 0.68 * glowBoost
            ctx.saveGState()
            ctx.scaleBy(x: width / max(width, height), y: height / max(width, height))
            ctx.drawRadialGradient(
                halo,
                startCenter: .zero, startRadius: max(width, height) * 0.22,
                endCenter: .zero, endRadius: haloRadius,
                options: []
            )
            ctx.restoreGState()
        }

        let eyePath = makeEyePath(width: width, height: height, params: params, roundness: morph)

        let isSleepy = (snap.mood == .sleeping || snap.mood == .sleepy)
        if let grad = isSleepy ? Self.sleepyEyeGradient : Self.normalEyeGradient {
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
            drawLid(ctx, width: width, height: height, amount: upperLid, angle: upperLidAngle, isTop: true)
            drawLid(ctx, width: width, height: height, amount: lowerLid, angle: lowerLidAngle, isTop: false)
            ctx.restoreGState()
        }

        ctx.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.setLineWidth(1.5)
        ctx.addPath(eyePath)
        ctx.strokePath()

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
            ctx.fill(CGRect(x: -width * 1.6, y: -height / 2.0 - 12.0, width: width * 3.2, height: cover + 12.5))
        } else {
            ctx.fill(CGRect(x: -width * 1.6, y: height / 2.0 - cover - 0.5, width: width * 3.2, height: cover + 12.0))
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

    // MARK: - Pointer & Context Menu

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
