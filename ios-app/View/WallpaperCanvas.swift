import SwiftUI

struct WallpaperCanvas: View {
    let project: WallpaperProject
    let size: CGSize
    var animated: Bool = true
    var stateProgress: Double? = nil
    var playCustomAnimations: Bool = true

    @State private var startT: TimeInterval? = nil

    private var scale: CGFloat { size.width / 1000 }

    private var anySpinning: Bool { project.layers.contains { $0.spin.enabled && !$0.isHidden } }
    private var anyCustomAnim: Bool {
        project.layers.contains { !$0.isHidden && $0.animations.contains { $0.keyframes.count >= 2 } }
    }
    private var anyAnimating: Bool { anySpinning || (playCustomAnimations && anyCustomAnim) }

    var body: some View {

        TimelineView(.animation(paused: !(animated && anyAnimating))) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let elapsed = t - (startT ?? t)
            ZStack {
                background
                ForEach(project.layers) { layer in
                    if !layer.isHidden {
                        let st = stateEffect(layer)
                        let kf = keyframeEffect(layer, elapsed: elapsed)
                        layerView(layer, rotation: kf.rotation)
                            .rotationEffect(spinAngle(layer, t))
                            .scaleEffect(x: st.scale * kf.scaleX, y: st.scale * kf.scaleY)
                            .position(x: kf.positionX.map { CGFloat($0) * size.width } ?? (layer.position.x + st.dx) * size.width,
                                      y: kf.positionY.map { CGFloat($0) * size.height } ?? (layer.position.y + st.dy) * size.height)
                            .opacity((kf.opacity ?? layer.opacity) * st.opacity)
                    }
                }
                if animated, project.particles.kind != .none {
                    ParticleOverlay(effect: project.particles, size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .onAppear { if startT == nil { startT = Date().timeIntervalSinceReferenceDate } }
    }

    private func spinAngle(_ layer: Layer, _ t: TimeInterval) -> Angle {
        guard animated, layer.spin.enabled, layer.spin.duration > 0 else { return .zero }
        let dir = layer.spin.clockwise ? 1.0 : -1.0
        let turns = (t / layer.spin.duration) * layer.spin.turns
        return .radians(dir * turns.truncatingRemainder(dividingBy: 1) * 2 * .pi)
    }

    // MARK: - Custom keyframe animations (preview playback)

    /// Interpolated keyframe effects for one layer at `elapsed` seconds after the canvas appeared.
    /// Position values are top-down editor space (X 0...390, Y 0...844), matching the exporter
    /// after its Y flip — so the preview shows exactly what the flashed wallpaper will do.
    private func keyframeEffect(_ layer: Layer, elapsed: TimeInterval) -> (positionX: Double?, positionY: Double?, opacity: Double?, rotation: Double?, scaleX: CGFloat, scaleY: CGFloat) {
        guard animated, playCustomAnimations else { return (nil, nil, nil, nil, 1, 1) }
        var posX: Double? = nil
        var posY: Double? = nil
        var op: Double? = nil
        var rot: Double? = nil
        var mulX: CGFloat = 1
        var mulY: CGFloat = 1
        for ca in layer.animations where ca.keyframes.count >= 2 {
            let v = keyframeValue(ca, elapsed: elapsed)
            switch ca.keyPath {
            case .positionX: posX = v / 390
            case .positionY: posY = v / 844
            case .opacity: op = v
            case .rotationZ: rot = v
            case .scale:
                let m = CGFloat(v / max(layer.scale, 0.01))
                mulX = m
                mulY = m
            case .scaleX: mulX = CGFloat(v / max(layer.scale, 0.01))
            case .scaleY: mulY = CGFloat(v / max(layer.scale, 0.01))
            case .boundsWidth, .boundsHeight, .cornerRadius:
                break
            }
        }
        return (posX, posY, op, rot, mulX, mulY)
    }

    private func keyframeValue(_ ca: CustomAnimation, elapsed: TimeInterval) -> Double {
        let frames = ca.keyframes
            .map { (time: max(0, min(1, $0.time)), value: $0.value) }
            .sorted { $0.time < $1.time }
        guard frames.count >= 2 else { return frames.first?.value ?? 0 }
        let p = animPhase(ca, elapsed: elapsed)
        if p <= frames[0].time { return frames[0].value }
        if p >= frames[frames.count - 1].time { return frames[frames.count - 1].value }
        for i in 1..<frames.count {
            if p <= frames[i].time {
                let a = frames[i - 1]
                let b = frames[i]
                let span = max(b.time - a.time, 0.0001)
                let local = applyTiming(ca.timing, (p - a.time) / span)
                return a.value + (b.value - a.value) * local
            }
        }
        return frames[frames.count - 1].value
    }

    /// 0...1 phase of the animation at `elapsed` seconds, honouring repeat / autoreverse.
    private func animPhase(_ ca: CustomAnimation, elapsed: TimeInterval) -> Double {
        let d = max(0.1, ca.duration)
        var cycle = (elapsed + ca.timeOffset) / d
        if ca.repeatForever {
            if ca.autoreverses {
                cycle = cycle.truncatingRemainder(dividingBy: 2)
                if cycle < 0 { cycle += 2 }
                return cycle > 1 ? 2 - cycle : cycle
            }
            cycle = cycle.truncatingRemainder(dividingBy: 1)
            if cycle < 0 { cycle += 1 }
            return cycle
        }
        if ca.autoreverses {
            if cycle <= 0 { return 0 }
            if cycle >= 2 { return 0 }
            return cycle > 1 ? 2 - cycle : cycle
        }
        return min(max(cycle, 0), 1)
    }

    private func applyTiming(_ timing: AnimTimingFunction, _ p: Double) -> Double {
        switch timing {
        case .linear: return p
        case .easeIn: return p * p
        case .easeOut: return 1 - (1 - p) * (1 - p)
        case .easeInOut:
            if p < 0.5 { return 2 * p * p }
            return 1 - pow(-2 * p + 2, 2) / 2
        }
    }

    private func stateEffect(_ layer: Layer) -> (dx: CGFloat, dy: CGFloat, opacity: Double, scale: CGFloat) {
        guard let p = stateProgress else { return (0, 0, 1, 1) }
        let s = layer.states
        let (lockP, homeP) = s.positions(base: layer.position)
        let curX = lockP.x + (homeP.x - lockP.x) * p
        let curY = lockP.y + (homeP.y - lockP.y) * p
        let lockO = s.onLock ? 1.0 : 0.0
        let homeO = s.onHome ? 1.0 : 0.0
        let opacity = lockO + (homeO - lockO) * p
        let scale = 1 + (s.homeScale - 1) * p
        return (CGFloat(curX - layer.position.x), CGFloat(curY - layer.position.y), opacity, CGFloat(scale))
    }

    @ViewBuilder
    private var background: some View {
        switch project.background {
        case let .solid(color):
            color.color
        case let .gradient(spec):
            gradientView(spec)
        case let .photo(imageID):
            if let img = ImageStore.shared.load(imageID) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Color.black
            }
        }
    }

    @ViewBuilder
    private func gradientView(_ spec: GradientSpec) -> some View {
        switch spec.kind {
        case .linear:
            let a = Angle(degrees: spec.angle)
            LinearGradient(gradient: spec.gradient,
                           startPoint: unitPoint(for: a, start: true),
                           endPoint: unitPoint(for: a, start: false))
        case .radial:
            RadialGradient(gradient: spec.gradient, center: .center,
                           startRadius: 0, endRadius: max(size.width, size.height) * 0.7)
        case .angular:
            AngularGradient(gradient: spec.gradient, center: .center,
                            angle: Angle(degrees: spec.angle))
        }
    }

    private func unitPoint(for angle: Angle, start: Bool) -> UnitPoint {
        let rad = angle.radians
        let dx = cos(rad) * 0.5, dy = sin(rad) * 0.5
        return start ? UnitPoint(x: 0.5 - dx, y: 0.5 - dy)
                     : UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
    }

    @ViewBuilder
    private func layerView(_ layer: Layer, rotation: Double? = nil) -> some View {
        Group {
            switch layer.content {
            case let .text(spec):
                textView(spec)
                    .scaleEffect(layer.scale)
            case let .photo(imageID, cornerRadius):
                if let img = ImageStore.shared.load(imageID) {

                    let aspect = img.size.height > 0 ? img.size.width / img.size.height : 1
                    let w = 600 * scale
                    let h = w / max(0.25, min(4, aspect))
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: w, height: h)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius * scale, style: .continuous))
                        .scaleEffect(layer.scale)
                }
            case let .sticker(symbol, color):
                Image(systemName: symbol)
                    .font(.system(size: 240 * scale, weight: .semibold))
                    .foregroundStyle(color.color)
                    .scaleEffect(layer.scale)
            }
        }
        .rotationEffect(.radians(rotation ?? layer.rotation))
    }

    @ViewBuilder
    private func textView(_ spec: TextSpec) -> some View {
        let font: Font = spec.fontName.isEmpty
            ? .system(size: spec.fontSize * scale, weight: spec.fontWeight)
            : .custom(spec.fontName, size: spec.fontSize * scale)
        Text(spec.string.isEmpty ? " " : spec.string)
            .font(font)
            .fontWeight(spec.fontName.isEmpty ? spec.fontWeight : nil)
            .tracking(spec.tracking * scale)
            .lineSpacing(spec.lineSpacing * scale)
            .multilineTextAlignment(spec.textAlignment)
            .foregroundStyle(spec.color.color)
            .frame(maxWidth: 880 * scale, alignment: spec.frameAlignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}
