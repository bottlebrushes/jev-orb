// @acid: ORB-1
import SwiftUI

public struct RealisticShadowModifier: ViewModifier {
    public let colors: [Color]
    public let radius: CGFloat

    public init(colors: [Color], radius: CGFloat) {
        self.colors = colors
        self.radius = radius
    }

    public func body(content: Content) -> some View {
        content
            .background {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: colors,
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .blur(radius: radius * 0.75)
                    .opacity(0.5)
                    .offset(y: radius * 0.5)
            }
            .background {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: colors,
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .blur(radius: radius * 3)
                    .opacity(0.3)
                    .offset(y: radius * 0.75)
            }
    }
}
