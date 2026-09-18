// @acid: ORB-1
import SwiftUI

public struct WavyBlobView: View {
    @State private var points: [CGPoint] = (0 ..< 6).map { index in
        let angle = (Double(index) / 6) * 2 * .pi
        return CGPoint(
            x: 0.5 + cos(angle) * 0.9,
            y: 0.5 + sin(angle) * 0.9
        )
    }

    private let color: Color
    private let loopDuration: Double

    public init(color: Color, loopDuration: Double = 1) {
        self.color = color
        self.loopDuration = max(loopDuration, 0.1)
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let timeNow = timeline.date.timeIntervalSinceReferenceDate
                let angle = (timeNow.remainder(dividingBy: loopDuration) / loopDuration) * 2 * .pi

                var path = Path()
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.45

                let adjustedPoints = points.enumerated().map { index, point in
                    let phaseOffset = Double(index) * .pi / 3
                    let xOffset = sin(angle + phaseOffset) * 0.15
                    let yOffset = cos(angle + phaseOffset) * 0.15
                    return CGPoint(
                        x: (point.x - 0.5 + xOffset) * radius + center.x,
                        y: (point.y - 0.5 + yOffset) * radius + center.y
                    )
                }

                path.move(to: adjustedPoints[0])

                for i in 0 ..< adjustedPoints.count {
                    let next = (i + 1) % adjustedPoints.count
                    let currentAngle = atan2(
                        adjustedPoints[i].y - center.y,
                        adjustedPoints[i].x - center.x
                    )
                    let nextAngle = atan2(
                        adjustedPoints[next].y - center.y,
                        adjustedPoints[next].x - center.x
                    )

                    let handleLength = radius * 0.33

                    let control1 = CGPoint(
                        x: adjustedPoints[i].x + cos(currentAngle + .pi / 2) * handleLength,
                        y: adjustedPoints[i].y + sin(currentAngle + .pi / 2) * handleLength
                    )

                    let control2 = CGPoint(
                        x: adjustedPoints[next].x + cos(nextAngle - .pi / 2) * handleLength,
                        y: adjustedPoints[next].y + sin(nextAngle - .pi / 2) * handleLength
                    )

                    path.addCurve(
                        to: adjustedPoints[next],
                        control1: control1,
                        control2: control2
                    )
                }

                context.fill(path, with: .color(color))
            }
        }
    }
}
