// @acid: ORB-1, ORB-2, ORB-3, ORB-4, ORB-5, ORB-6
import SwiftUI

public struct OrbConfiguration {
    public var glowColor: Color
    public var backgroundColors: [Color]
    public var particleColor: Color
    
    public var showBackground: Bool
    public var showWavyBlobs: Bool
    public var showParticles: Bool
    public var showGlowEffects: Bool
    public var showShadow: Bool
    
    public var coreGlowIntensity: Double
    public var speed: Double
    
    public init(
        backgroundColors: [Color] = [.cyan, .indigo, .purple],
        glowColor: Color = .white,
        particleColor: Color = .white,
        coreGlowIntensity: Double = 1.0,
        showBackground: Bool = true,
        showWavyBlobs: Bool = true,
        showParticles: Bool = true,
        showGlowEffects: Bool = true,
        showShadow: Bool = true,
        speed: Double = 60
    ) {
        self.backgroundColors = backgroundColors
        self.glowColor = glowColor
        self.particleColor = particleColor
        self.coreGlowIntensity = coreGlowIntensity
        self.showBackground = showBackground
        self.showWavyBlobs = showWavyBlobs
        self.showParticles = showParticles
        self.showGlowEffects = showGlowEffects
        self.showShadow = showShadow
        self.speed = speed
    }

    // Presets for different states
    public static var idle: OrbConfiguration {
        OrbConfiguration(
            backgroundColors: [.blue.opacity(0.7), .purple.opacity(0.8), .indigo.opacity(0.9)],
            glowColor: .cyan.opacity(0.6),
            coreGlowIntensity: 0.8,
            speed: 35
        )
    }

    public static var listening: OrbConfiguration {
        OrbConfiguration(
            backgroundColors: [.cyan, .purple, .pink],
            glowColor: .white,
            coreGlowIntensity: 1.4,
            speed: 70
        )
    }

    public static var thinking: OrbConfiguration {
        OrbConfiguration(
            backgroundColors: [.purple, .pink, .indigo],
            glowColor: .white,
            coreGlowIntensity: 1.6,
            speed: 100
        )
    }

    public static var success: OrbConfiguration {
        OrbConfiguration(
            backgroundColors: [.teal, .mint, .green],
            glowColor: .mint,
            coreGlowIntensity: 1.5,
            speed: 50
        )
    }
}
