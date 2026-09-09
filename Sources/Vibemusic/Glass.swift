import SwiftUI

extension View {
    /// Liquid-glass: материал + световой ободок + блик сверху + мягкая тень.
    @ViewBuilder
    func liquidGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        glare: Bool = true
    ) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                if interactive {
                    self.glassEffect((tint.map { Glass.regular.tint($0) } ?? .regular).interactive(), in: shape)
                } else {
                    self.glassEffect((tint.map { Glass.regular.tint($0) } ?? .regular), in: shape)
                }
            } else {
                self.background(
                    shape.fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.22), radius: 12, y: 8)
                )
            }
        }
        .overlay(
            shape.stroke(
                LinearGradient(
                    colors: [.white.opacity(0.70), .white.opacity(0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
        )
        .overlay(
            Group {
                if glare {
                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.30), location: 0.0),
                                .init(color: .white.opacity(0.06), location: 0.42),
                                .init(color: .white.opacity(0.0), location: 0.55),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                }
            }
            .allowsHitTesting(false)
        )
    }

    func glassCard(shape: some Shape, tint: Color? = nil) -> some View {
        liquidGlass(in: shape, tint: tint)
    }

    func glassCircle(diameter: CGFloat, tint: Color? = nil) -> some View {
        frame(width: diameter, height: diameter)
            .liquidGlass(in: Circle(), tint: tint)
    }
}

struct LiquidContainer<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}
