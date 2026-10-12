import SwiftUI
import BlackTeamKit

/// What the emblem is showing. Only live work glows; offline, approval and stopping stay still.
enum AvatarState: Equatable {
    case idle, preparing, thinking, responding, working

    init(_ activity: ResponseActivity?) {
        guard let activity, activity.glowing else { self = .idle; return }
        switch activity.phase {
        case .preparing: self = .preparing
        case .thinking: self = .thinking
        case .responding: self = .responding
        default: self = .working
        }
    }
    var isActive: Bool { self != .idle }
}

/// The emblem as the assistant's avatar, with a ring that breathes and orbits only while the model works.
/// With Reduce Motion on, the ring is shown still.
struct AgentAvatar: View {
    var state: AvatarState = .idle
    var large = false
    var diameter: CGFloat?
    @Environment(\.btTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: AvatarState = .idle, large: Bool = false, diameter: CGFloat? = nil) { self.state = state; self.large = large; self.diameter = diameter }
    init(activity: ResponseActivity?, large: Bool = false) { self.init(state: AvatarState(activity), large: large) }

    private var size: CGFloat { diameter ?? (large ? 76 : 42) }

    var body: some View {
        ZStack {
            Circle().fill(.black)
            if let mark = BrandArt.mark {
                Image(decorative: mark, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit).clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(theme.line2, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        .overlay {
            if state.isActive {
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    ring(at: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
                }
                .frame(width: size + 8, height: size + 8)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(state.isActive ? "Black Team is working" : "Black Team")
    }

    private func ring(at t: TimeInterval) -> some View {
        let breathe = 0.75 + 0.25 * cos(2 * .pi * t / 2.6)           // opacity 1 down to 0.5
        let angle = Angle.degrees(360 * (t.truncatingRemainder(dividingBy: 2.2)) / 2.2)
        return ZStack {
            Circle().stroke(theme.accent, lineWidth: 1)
                .shadow(color: theme.ring, radius: 4.5)
                .shadow(color: theme.ring, radius: 11)
                .opacity(breathe)
            ZStack {
                Circle().trim(from: 0.625, to: 0.875).stroke(theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                Circle().trim(from: 0.875, to: 1.0).stroke(theme.ring, lineWidth: 2)
                Circle().trim(from: 0, to: 0.125).stroke(theme.ring, lineWidth: 2)
            }
            .rotationEffect(angle)
        }
    }
}
