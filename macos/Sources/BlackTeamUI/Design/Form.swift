import SwiftUI

// The form pieces of app.css: `.form-field`, `.file-picker`, `.connection-card`, `.provider-card`, `.form-actions`.

/// `<label class="form-field">`: a 12 point semibold label, the control 8 points under it, an optional hint.
struct BTFormField<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: Content
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).btBody(12, 1.5, theme.ink, weight: .semibold)
            content
            if let hint { Text(hint).btBody(11, 1.6, theme.muted).padding(.top, -4) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// `.file-picker`: a field-coloured bar with a name and a path on the left and a button on the right.
struct BTFileRow<Trailing: View>: View {
    let title: String
    let value: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(BTFont.body(12.5, .semibold)).foregroundStyle(theme.ink).frame(height: 19.5, alignment: .leading)
                Text(value).btBody(11, 1.6, theme.muted).padding(.top, 4 - 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 17).padding(.vertical, 15)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line, lineWidth: 1))
    }
}

/// `.connection-card`: a surface card with a heading, a paragraph, a mono status line and an action on the right.
struct BTConnectionCard<Action: View>: View {
    let title: String
    let text: String
    var status: String?
    var ready = false
    var heading = true
    var aside: String?
    @ViewBuilder var action: Action
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(BTFont.body(heading ? 13 : 13, .semibold)).foregroundStyle(theme.ink).frame(height: 19.5, alignment: .leading).padding(.bottom, 6)
                Text(text).btBody(12, 1.6, theme.muted)
                if let status {
                    Text(status).font(BTFont.mono(10)).tracking(0.6).foregroundStyle(ready ? theme.ok : theme.muted).frame(height: 15, alignment: .leading).padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let aside { Text(aside).btBody(11, 1.6, theme.muted).frame(maxWidth: 330, alignment: .leading) }
            action
        }
        .padding(.horizontal, 21).padding(.vertical, 19)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line, lineWidth: 1))
    }
}

/// `.provider-card`: a selectable card in a two column grid.
struct BTProviderCard: View {
    let name: String
    let summary: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.btTheme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(BTFont.body(13, .semibold)).foregroundStyle(theme.ink).frame(height: 19.5, alignment: .leading)
                Text(summary).btBody(12, 1.5, theme.muted)
            }
            .padding(.horizontal, 19).padding(.vertical, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(selected ? theme.surface2 : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(selected ? theme.accent : theme.line2, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(selected ? theme.accent : .clear, lineWidth: 1).padding(1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// `.form-actions`: the primary action and a muted note beside it.
struct BTFormActions<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { HStack(spacing: 18) { content; Spacer(minLength: 0) } }
}

/// Two columns with a 20 point gap, as `fieldset { display: grid; grid-template-columns: 1fr 1fr; gap: 20px }`.
struct BTTwoColumns<Content: View>: View {
    var gap: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View { FractionalColumns(fractions: [1, 1], spacing: gap) { content } }
}
