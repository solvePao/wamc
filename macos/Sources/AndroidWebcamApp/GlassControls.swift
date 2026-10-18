import SwiftUI

/// Related glass controls share one sampling region on macOS 26 and later.
struct GlassControlGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
    }
}

private struct AdaptiveGlassSurface: ViewModifier {
    var interactive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular,
                                in: RoundedRectangle(cornerRadius: 12))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct AdaptiveActionStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.1, *), prominent {
            // Use the same native glass geometry for both columns. The
            // prominent style has different intrinsic insets on macOS.
            content.buttonStyle(.glass(.regular.tint(.accentColor)))
                .buttonSizing(.flexible)
                .frame(height: 36)
        } else if #available(macOS 26, *) {
            content.buttonStyle(.glass)
                .tint(prominent ? Color.accentColor : nil)
                .buttonSizing(.flexible)
                .frame(height: 36)
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    func wamcGlassSurface(interactive: Bool = false) -> some View {
        modifier(AdaptiveGlassSurface(interactive: interactive))
    }

    func wamcActionStyle(prominent: Bool = false) -> some View {
        modifier(AdaptiveActionStyle(prominent: prominent))
    }
}

/// The label and empty row space toggle the disclosure, not just its chevron.
struct FullRowDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    configuration.label
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .wamcGlassSurface(interactive: true)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide this section")

            if configuration.isExpanded {
                configuration.content
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
    }
}
