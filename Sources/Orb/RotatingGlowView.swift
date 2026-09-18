// @acid: ORB-1
import SwiftUI

public enum RotationDirection {
    case clockwise
    case counterClockwise

    public var multiplier: Double {
        switch self {
        case .clockwise: return 1
        case .counterClockwise: return -1
        }
    }
}

public struct RotatingGlowView: View {
    @State private var rotation: Double = 0

    private let color: Color
    private let rotationSpeed: Double
    private let direction: RotationDirection

    public init(
        color: Color,
        rotationSpeed: Double = 30,
        direction: RotationDirection
    ) {
        self.color = color
        self.rotationSpeed = rotationSpeed
        self.direction = direction
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)

            Circle()
                .fill(color)
                .mask {
                    ZStack {
                        Circle()
                            .frame(width: size, height: size)
                            .blur(radius: size * 0.16)
                        Circle()
                            .frame(width: size * 1.31, height: size * 1.31)
                            .offset(y: size * 0.31)
                            .blur(radius: size * 0.16)
                            .blendMode(.destinationOut)
                    }
                }
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 360 / max(rotationSpeed, 1.0)).repeatForever(autoreverses: false)) {
                        rotation = 360 * direction.multiplier
                    }
                }
        }
    }
}
