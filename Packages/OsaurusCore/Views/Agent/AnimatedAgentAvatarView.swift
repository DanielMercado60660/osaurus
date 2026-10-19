import SwiftUI

/// A future RealityKit renderer only needs these presentation inputs; it never
/// needs to know about chat sessions, microphones, or TTS singletons.
@MainActor
protocol AvatarRenderer: View {
    init(mood: AvatarMood, tint: Color, time: TimeInterval, reduceMotion: Bool)
}

struct AnimatedAgentAvatarView: View {
    var mood: AvatarMood
    var tint: Color
    var isVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var windowVisible = false
    @State private var blinkSeed = Double.random(in: 0 ... 500)

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: mood.isSpeaking ? 1.0 / 30 : 0.1,
                paused: !isVisible || !appeared || !windowVisible || reduceMotion
            )
        ) { timeline in
            DinosaurAvatarRenderer(
                mood: mood,
                tint: tint,
                time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate + blinkSeed,
                reduceMotion: reduceMotion
            )
        }
        .background(AvatarWindowVisibility { visible, _ in windowVisible = visible })
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Animated agent")
        .accessibilityValue(mood.accessibilityDescription)
    }
}

/// A pocket-sized dinosaur: oversized muzzle, soft belly, dorsal plates,
/// tiny hands and planted feet. All paths use a 160-point design coordinate space.
struct DinosaurAvatarRenderer: AvatarRenderer {
    let mood: AvatarMood
    let tint: Color
    let time: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 160
            context.translateBy(x: (size.width - 160 * scale) / 2, y: (size.height - 160 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            draw(in: &context)
        }
    }

    private func draw(in context: inout GraphicsContext) {
        let ink = Color(red: 0.09, green: 0.16, blue: 0.22)
        let cream = Color(red: 1, green: 0.94, blue: 0.79)
        let listening: CGFloat = if case .listening(let level) = mood { CGFloat(level) } else { 0 }
        let attentive: Bool = if case .listening = mood { true } else { false }
        let thinking = mood == .thinking
        let worried = mood == .error
        let mouth: CGFloat = if case .speaking(let level) = mood { CGFloat(level) } else { 0 }
        let breath = reduceMotion ? 0 : sin(time * 1.7) * 1.5
        // Each 5-second window has a different blink onset and an occasional
        // double blink. Stable within a frame; no timers or per-frame randomness.
        let cycle = floor(time / 5)
        let noise = abs(sin(cycle * 78.233) * 43758.5453).truncatingRemainder(dividingBy: 1)
        let phase = time.truncatingRemainder(dividingBy: 5) - (1.4 + noise * 2)
        let blink = !reduceMotion && ((phase > 0 && phase < 0.17) || (noise > 0.72 && phase > 0.3 && phase < 0.43))

        func oval(_ rect: CGRect, _ color: Color) {
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
        oval(CGRect(x: 36, y: 143, width: 90, height: 8), ink.opacity(0.10))
        if attentive {
            let ring = CGRect(
                x: 13 - listening * 3,
                y: 10 - listening * 3,
                width: 134 + listening * 6,
                height: 134 + listening * 6
            )
            context.stroke(
                Path(ellipseIn: ring),
                with: .color(tint.opacity(0.22 + Double(listening) * 0.3)),
                lineWidth: 2
            )
        }
        // Tail curls around the belly instead of reading as a circular face.
        var tail = Path()
        tail.move(to: CGPoint(x: 110, y: 116))
        tail.addQuadCurve(to: CGPoint(x: 145, y: 105), control: CGPoint(x: 148, y: 142))
        tail.addQuadCurve(to: CGPoint(x: 109, y: 139), control: CGPoint(x: 150, y: 151))
        tail.closeSubpath()
        context.fill(tail, with: .color(tint.opacity(0.85)))
        oval(CGRect(x: 45, y: 134, width: 29, height: 13), tint)
        oval(CGRect(x: 91, y: 134, width: 29, height: 13), tint)

        context.translateBy(x: 0, y: breath - (attentive ? 3 : 0))
        oval(CGRect(x: 46, y: 87, width: 73, height: 55 + mouth * 2), tint)
        oval(CGRect(x: 62, y: 102, width: 42, height: 37), cream)
        // Three little leaf-shaped dorsal plates.
        for index in 0 ..< 3 {
            let x = CGFloat(47 + index * 17)
            var plate = Path()
            plate.move(to: CGPoint(x: x, y: 42))
            plate.addQuadCurve(to: CGPoint(x: x + 7, y: 20 - CGFloat(index % 2) * 6), control: CGPoint(x: x - 2, y: 21))
            plate.addQuadCurve(to: CGPoint(x: x + 20, y: 41), control: CGPoint(x: x + 24, y: 26))
            plate.closeSubpath()
            context.fill(plate, with: .color(tint.opacity(0.7)))
        }
        let head = Path(roundedRect: CGRect(x: 36, y: 34, width: 88, height: 72), cornerRadius: 30)
        context.fill(
            head,
            with: .linearGradient(
                Gradient(colors: [tint.opacity(0.78), tint]),
                startPoint: CGPoint(x: 40, y: 35),
                endPoint: CGPoint(x: 110, y: 106)
            )
        )
        // Eye sockets give the character a distinctive binocular dino silhouette.
        for x in [CGFloat(51), 87] {
            oval(CGRect(x: x, y: 47, width: 24, height: 29), cream)
            if blink {
                var lid = Path()
                lid.move(to: CGPoint(x: x + 5, y: 61))
                lid.addQuadCurve(to: CGPoint(x: x + 19, y: 61), control: CGPoint(x: x + 12, y: 66))
                context.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            } else {
                let eyeY: CGFloat = thinking ? 49 : (worried ? 60 : 55)
                oval(CGRect(x: x + (thinking ? 10 : 8), y: eyeY, width: 10, height: attentive ? 16 : 13), ink)
                oval(CGRect(x: x + 10, y: eyeY + 2, width: 3, height: 4), .white)
            }
        }
        // Broad rounded muzzle and nostrils, not a generic emoji smile.
        oval(CGRect(x: 39, y: 72, width: 87, height: 37 + mouth * 5), tint)
        oval(CGRect(x: 51, y: 80, width: 4, height: 3), ink.opacity(0.45))
        oval(CGRect(x: 109, y: 80, width: 4, height: 3), ink.opacity(0.45))
        if mouth > 0.015 {
            oval(CGRect(x: 69, y: 92, width: 28, height: 3 + mouth * 15), ink)
            oval(CGRect(x: 76, y: 94 + mouth * 8, width: 14, height: 2 + mouth * 5), .pink.opacity(0.85))
        } else {
            var smile = Path()
            smile.move(to: CGPoint(x: 65, y: 94))
            smile.addQuadCurve(to: CGPoint(x: 101, y: 94), control: CGPoint(x: 83, y: worried ? 86 : 104))
            context.stroke(smile, with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            if !worried {
                context.fill(
                    Path(roundedRect: CGRect(x: 94, y: 96, width: 4, height: 6), cornerRadius: 1),
                    with: .color(cream)
                )
            }
        }
        oval(CGRect(x: 40, y: 89, width: 13, height: 6), .pink.opacity(0.3))
        oval(CGRect(x: 114, y: 89, width: 10, height: 6), .pink.opacity(0.3))
        // Tiny arms lifted while listening; belly spots add character at idle.
        oval(CGRect(x: 39, y: attentive ? 101 : 111, width: 17, height: 11), tint)
        oval(CGRect(x: 109, y: attentive ? 101 : 111, width: 17, height: 11), tint)
        for x in [CGFloat(74), 84, 94] {
            oval(CGRect(x: x, y: 119, width: 3, height: 4), tint.opacity(0.35))
        }
        if thinking {
            for index in 0 ..< 3 {
                let angle = (reduceMotion ? -1.2 : time * 1.8) + Double(index) * 0.65
                oval(
                    CGRect(
                        x: 120 + cos(angle) * 14,
                        y: 28 + sin(angle) * 12,
                        width: CGFloat(4 + index),
                        height: CGFloat(4 + index)
                    ),
                    tint.opacity(0.4 + Double(index) * 0.2)
                )
            }
        }
        if worried {
            context.draw(
                Text("!").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(tint),
                at: CGPoint(x: 135, y: 44)
            )
        }
    }
}

private struct AvatarMoodPreview: View {
    @State private var index = 0
    private let moods: [AvatarMood] = [.idle, .listening(0.6), .thinking, .speaking(0.8), .error]
    var body: some View {
        VStack {
            AnimatedAgentAvatarView(mood: moods[index], tint: AgentMascot.green.color)
                .frame(width: 240, height: 240)
            Text(moods[index].accessibilityDescription)
        }
        .padding(24)
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                index = (index + 1) % moods.count
            }
        }
    }
}

#Preview("Every avatar mood") { AvatarMoodPreview() }
