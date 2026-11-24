import SwiftUI

struct PostcardBurn {
    static let ignition = 1.94
    static let duration = 4.65

    let time: Double
    let size: CGSize

    func remainingPaper() -> Path {
        guard time >= Self.ignition else { return Path(CGRect(origin: .zero, size: size)) }
        var paper = Path()
        paper.addLines(edge(at: time).map { point in
            CGPoint(x: point.x, y: min(size.height, max(0, point.y)))
        })
        paper.addLine(to: CGPoint(x: size.width, y: size.height))
        paper.addLine(to: CGPoint(x: 0, y: size.height))
        paper.closeSubpath()
        return paper
    }

    func drawScorch(in context: GraphicsContext) {
        guard time >= Self.ignition else { return }
        let front = edge(at: time)
        let char = band(along: front, from: -2, to: 5)
        let singe = band(along: front, from: 3, to: 16)
        var shadow = context
        shadow.addFilter(.blur(radius: 3))
        shadow.fill(singe, with: .color(Color(red: 0.40, green: 0.15, blue: 0.07).opacity(0.54)))
        context.fill(char, with: .color(Color(red: 0.15, green: 0.065, blue: 0.045).opacity(0.91)))
    }

    func drawLight(in context: GraphicsContext, bleed: CGFloat) {
        var fire = context
        fire.translateBy(x: bleed, y: bleed)
        let age = time - Self.ignition
        let front = edge(at: time)
        let rim = burningRim(front)
        let heat = smooth((age - 0.03) / 0.13)
        var bloom = fire
        bloom.addFilter(.blur(radius: 11))
        bloom.stroke(rim, with: .color(Self.ember.opacity(0.77 * heat)),
                     style: StrokeStyle(lineWidth: 24, lineCap: .round, lineJoin: .round))

        for slot in 0..<23 {
            let offset = Double(slot) * 0.37
            let x = (Double(slot) + noise(slot, 2) * 0.68) / 23
            let y = burnY(at: x, time: time)
            guard y > -3, y < size.height + 3 else { continue }
            let flicker = 0.60 + 0.23 * sin(age * 13 + offset) + 0.15 * sin(age * 19 + offset * 3)
            let length = (15 + noise(slot, 4) * 32) * flicker * heat
            let root = CGPoint(x: size.width * x, y: y)
            let bend = sin(age * 7 + offset) * 9
            drawFlame(in: fire, root: root, length: length, bend: bend, width: 3 + noise(slot, 8) * 6)
        }

        fire.stroke(rim, with: .color(Self.ember.opacity(0.86 * heat)),
                    style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round))
        fire.stroke(rim, with: .color(Self.hot.opacity(0.91 * heat)),
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
        drawSparks(in: fire, age: age)
    }

    private func drawFlame(in context: GraphicsContext, root: CGPoint, length: Double,
                           bend: Double, width: Double) {
        let tip = CGPoint(x: root.x + bend, y: root.y - length)
        var tongue = Path()
        tongue.move(to: CGPoint(x: root.x - width, y: root.y + 1))
        tongue.addQuadCurve(to: tip, control: CGPoint(x: root.x - width * 1.3, y: root.y - length * 0.52))
        tongue.addQuadCurve(to: CGPoint(x: root.x + width, y: root.y + 1),
                            control: CGPoint(x: root.x + width * 1.5, y: root.y - length * 0.42))
        tongue.closeSubpath()
        context.fill(tongue, with: .linearGradient(
            Gradient(stops: [
                .init(color: Self.hot.opacity(0.95), location: 0),
                .init(color: Self.ember.opacity(0.61), location: 0.36),
                .init(color: Self.ember.opacity(0), location: 1)
            ]),
            startPoint: root, endPoint: tip
        ))
    }

    private func drawSparks(in context: GraphicsContext, age: Double) {
        for index in 0..<100 {
            let born = 0.08 + Double(index) * 0.018 + noise(index, 17) * 0.13
            let lifetime = 0.30 + noise(index, 13) * 0.76
            let elapsed = age - born
            guard elapsed > 0, elapsed < lifetime else { continue }
            let column = noise(index, 4)
            let floor = burnY(at: column, time: Self.ignition + born)
            guard floor >= -2, floor <= size.height else { continue }
            let travel = elapsed / lifetime
            let rise = 24 + noise(index, 5) * 128
            let drift = (noise(index, 7) - 0.4) * 72
            let x = size.width * column + drift * elapsed + 4 * sin(elapsed * 11 + Double(index))
            let y = floor - rise * elapsed - 20 * elapsed * elapsed
            let shine = smooth(elapsed / 0.055) * pow(1 - travel, 1.30)
            let radius = (0.70 + noise(index, 9) * 1.55) * (1 - 0.34 * travel)
            let point = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            if radius > 1.3 {
                let haloRadius = radius * 3.4
                let halo = CGRect(x: x - haloRadius, y: y - haloRadius, width: haloRadius * 2, height: haloRadius * 2)
                context.fill(Path(ellipseIn: halo), with: .radialGradient(
                    Gradient(colors: [Self.ember.opacity(shine * 0.55), .clear]),
                    center: CGPoint(x: x, y: y), startRadius: 0, endRadius: haloRadius
                ))
            }
            let sparkColor = index.isMultiple(of: 3) ? Self.ember : Self.hot
            context.fill(Path(ellipseIn: point), with: .color(sparkColor.opacity(shine)))
        }
    }

    private func edge(at time: Double) -> [CGPoint] {
        (0...68).map { sample in
            let x = Double(sample) / 68
            return CGPoint(x: size.width * x, y: burnY(at: x, time: time))
        }
    }

    private func burnY(at x: Double, time: Double) -> CGFloat {
        let age = time - Self.ignition
        let distance = abs(x - 0.27)
        let delay = 0.21 * distance + 0.39 * distance * distance
        let progress = max(0, (age - delay) / 1.63)
        let scallops = 0.023 * sin(43 * x + age * 7) + 0.019 * sin(15 * x - age * 6)
        let grain = 0.009 * (sin(117 * x + age * 12) + sin(181 * x - age * 11))
        let front = -0.034 + progress * (0.91 + 0.29 * min(1, progress))
        return size.height * (front + (scallops + grain) * smooth(progress * 9))
    }

    private func burningRim(_ front: [CGPoint]) -> Path {
        var outline = Path()
        var onPaper = false
        for point in front {
            let touchesPaper = point.y >= -2 && point.y <= size.height + 2
            if touchesPaper {
                if onPaper { outline.addLine(to: point) } else { outline.move(to: point) }
            }
            onPaper = touchesPaper
        }
        return outline
    }

    private func band(along front: [CGPoint], from start: CGFloat, to end: CGFloat) -> Path {
        var path = Path()
        path.addLines(front.map { CGPoint(x: $0.x, y: $0.y + start) })
        for point in front.reversed() {
            path.addLine(to: CGPoint(x: point.x, y: point.y + end))
        }
        path.closeSubpath()
        return path
    }

    private func noise(_ index: Int, _ stream: Int) -> Double {
        let value = sin(Double(index * 41 + stream * 113) * 12.9898) * 43758.5453
        return value - floor(value)
    }

    private func smooth(_ x: Double) -> Double {
        let p = min(1, max(0, x))
        return p * p * (3 - 2 * p)
    }

    private static let ember = Color(red: 1, green: 0.33, blue: 0.095)
    private static let hot = Color(red: 1, green: 0.88, blue: 0.60)
}
