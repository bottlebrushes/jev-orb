// @acid: ORB-1
import SwiftUI

public struct ParticlesView: View {
    public let color: Color
    public let particleCount: Int
    
    public init(
        color: Color = .white,
        particleCount: Int = 18
    ) {
        self.color = color
        self.particleCount = particleCount
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxRadius = min(size.width, size.height) * 0.42

                for i in 0..<particleCount {
                    let seed = Double(i) * 137.5
                    let speed = 0.4 + (Double(i % 5) * 0.15)
                    let angle = (time * speed + seed).remainder(dividingBy: 2 * .pi)
                    let dist = (sin(time * 0.8 + Double(i)) * 0.5 + 0.5) * maxRadius
                    
                    let x = center.x + cos(angle) * dist
                    let y = center.y + sin(angle) * dist
                    let particleSize = 1.5 + (sin(Double(i) + time * 2) + 1.0) * 1.5
                    let opacity = 0.2 + (sin(time * 1.5 + seed) * 0.5 + 0.5) * 0.6

                    let rect = CGRect(
                        x: x - particleSize / 2,
                        y: y - particleSize / 2,
                        width: particleSize,
                        height: particleSize
                    )

                    context.opacity = opacity
                    context.fill(Circle().path(in: rect), with: .color(color))
                }
            }
        }
    }
}
