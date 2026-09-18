// @acid: ORB-1, ORB-2, ORB-3, ORB-4, ORB-5, ORB-6
import SwiftUI

public struct OrbView: View {
    private let config: OrbConfiguration
    
    public init(configuration: OrbConfiguration = OrbConfiguration()) {
        self.config = configuration
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)

            ZStack {
                if config.showBackground {
                    background
                }
                
                baseDepthGlows(size: size)

                if config.showWavyBlobs {
                    wavyBlob
                    wavyBlobTwo
                }

                if config.showGlowEffects {
                    coreGlowEffects(size: size)
                }

                if config.showParticles {
                    ParticlesView(color: config.particleColor)
                        .frame(maxWidth: size, maxHeight: size)
                }
            }
            .overlay {
                realisticInnerGlows
            }
            .mask {
                Circle()
            }
            .aspectRatio(1, contentMode: .fit)
            .modifier(
                RealisticShadowModifier(
                    colors: config.showShadow ? config.backgroundColors : [.clear],
                    radius: size * 0.08
                )
            )
        }
    }

    private var background: some View {
        LinearGradient(
            colors: config.backgroundColors,
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private var orbOutlineColor: LinearGradient {
        LinearGradient(
            colors: [.white, .clear],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private var wavyBlob: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)

            RotatingGlowView(
                color: .white.opacity(0.75),
                rotationSpeed: config.speed * 1.5,
                direction: .clockwise
            )
            .mask {
                WavyBlobView(color: .white, loopDuration: 60 / max(config.speed, 1.0) * 1.75)
                    .frame(maxWidth: size * 1.875)
                    .offset(x: 0, y: size * 0.31)
            }
            .blur(radius: 1)
            .blendMode(.plusLighter)
        }
    }

    private var wavyBlobTwo: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)

            RotatingGlowView(
                color: .white,
                rotationSpeed: config.speed * 0.75,
                direction: .counterClockwise
            )
            .mask {
                WavyBlobView(color: .white, loopDuration: 60 / max(config.speed, 1.0) * 2.25)
                    .frame(maxWidth: size * 1.25)
                    .rotationEffect(.degrees(90))
                    .offset(x: 0, y: size * -0.31)
            }
            .opacity(0.5)
            .blur(radius: 1)
            .blendMode(.plusLighter)
        }
    }

    private func coreGlowEffects(size: CGFloat) -> some View {
        ZStack {
            RotatingGlowView(
                color: config.glowColor,
                rotationSpeed: config.speed * 3,
                direction: .clockwise
            )
            .blur(radius: size * 0.08)
            .opacity(config.coreGlowIntensity)

            RotatingGlowView(
                color: config.glowColor,
                rotationSpeed: config.speed * 2.3,
                direction: .clockwise
            )
            .blur(radius: size * 0.06)
            .opacity(config.coreGlowIntensity)
            .blendMode(.plusLighter)
        }
        .padding(size * 0.08)
    }

    private func baseDepthGlows(size: CGFloat) -> some View {
        ZStack {
            RotatingGlowView(
                color: config.glowColor,
                rotationSpeed: config.speed * 0.75,
                direction: .counterClockwise
            )
            .padding(size * 0.03)
            .blur(radius: size * 0.06)
            .rotationEffect(.degrees(180))
            .blendMode(.destinationOver)
            
            RotatingGlowView(
                color: config.glowColor.opacity(0.5),
                rotationSpeed: config.speed * 0.25,
                direction: .clockwise
            )
            .frame(maxWidth: size * 0.94)
            .rotationEffect(.degrees(180))
            .padding(8)
            .blur(radius: size * 0.032)
        }
    }

    private var realisticInnerGlows: some View {
        ZStack {
            Circle()
                .stroke(orbOutlineColor, lineWidth: 8)
                .blur(radius: 32)
                .blendMode(.plusLighter)

            Circle()
                .stroke(orbOutlineColor, lineWidth: 4)
                .blur(radius: 12)
                .blendMode(.plusLighter)
            
            Circle()
                .stroke(orbOutlineColor, lineWidth: 1)
                .blur(radius: 4)
                .blendMode(.plusLighter)
        }
        .padding(1)
    }
}
