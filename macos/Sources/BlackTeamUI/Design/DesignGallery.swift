import SwiftUI
import BlackTeamKit

/// Every component on one scrollable page, so the look can be checked against the Linux app.
public struct DesignGallery: View {
    private let forcing: ThemeSetting?
    private let flat: Bool

    /// `forcing` pins a theme (otherwise the saved choice applies); `flat` lays the page out without
    /// scroll views, which is what image rendering needs.
    public init(forcing: ThemeSetting? = nil, flat: Bool = false) {
        self.forcing = forcing
        self.flat = flat
        Fonts.register()
    }

    public var body: some View {
        GalleryContent(flat: flat)
            .environment(\.btFlatLayout, flat)
            .blackTeamTheme(forcing: forcing)
    }
}

private struct GalleryContent: View {
    let flat: Bool
    @Environment(\.btTheme) private var theme
    @AppStorage(ThemeSetting.storageKey) private var stored = ThemeSetting.system.rawValue
    @State private var mode = AppMode.chat
    @State private var text = ""
    @State private var banner = true

    private let sampleMarkdown = """
    # Done

    Ran **`count.py`** and it *worked*, ~~no~~ really. See [the docs](https://example.org/a).

    - **Modified** `a.py`
      - nested item
    - Ran it

    3. one
    4. two

    > Noted: replies stay on this Mac.

    ```python
    def total(rows):
        return sum(r.amount for r in rows)
    ```

    | Model | Speed |
    |---|---:|
    | Qwen 3.8 | **49** |
    | Ornith 1.5 | 31 |
    """

    private let sampleDiff = """
    --- a/count.py
    +++ b/count.py
    @@ -1,5 +1,6 @@
     import sys
    -def total(rows): return 0
    +def total(rows):
    +    return sum(r.amount for r in rows)

     print(total([]))
    """

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 28) {
            header
            section("Brand") {
                HStack(spacing: 28) {
                    BrandWordmark().frame(width: 260)
                    BrandEmblem(size: 64)
                }
            }
            section("Agent avatar") {
                HStack(spacing: 28) {
                    avatar("idle", .idle); avatar("preparing", .preparing); avatar("thinking", .thinking)
                    avatar("responding", .responding); avatar("working", .working)
                    VStack(spacing: 8) { AgentAvatar(state: .thinking, large: true); caption("large") }
                }
            }
            section("Buttons") {
                HStack(spacing: 10) {
                    Button { } label: { Label { Text("Start model") } icon: { IconView(.play, size: 15) } }.buttonStyle(.btPrimary)
                    Button("Secondary") { }.buttonStyle(.btSecondary)
                    Button("Stop") { }.buttonStyle(.btDanger)
                    Button { } label: { Label { Text("Refresh") } icon: { IconView(.refresh, size: 15) } }.buttonStyle(.btQuiet)
                    Button("Disabled") { }.buttonStyle(.btPrimary).disabled(true)
                }
            }
            section("Status, mode and gauge") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        BTStatusPill(text: "IN USE")
                        BTStatusPill(text: "ONLINE", kind: .ok, showsDot: true)
                        BTStatusPill(text: "LOADING", kind: .warn, showsDot: true)
                        BTStatusPill(text: "OFFLINE", kind: .bad, showsDot: true)
                    }
                    BTModeSwitch(mode: $mode)
                    VStack(alignment: .leading, spacing: 6) {
                        caption("Memory 62%")
                        BTGauge(value: 0.62).frame(width: 320)
                    }
                }
            }
            section("Text field") {
                BTTextField("Message Black Team", text: $text).frame(maxWidth: 420)
            }
            section("Icons") {
                HStack(spacing: 18) {
                    ForEach(BTIcon.allCases, id: \.self) { icon in
                        VStack(spacing: 6) { IconView(icon); caption(icon.rawValue) }
                    }
                }
            }
            section("Banners") {
                VStack(spacing: 10) {
                    BTBanner(kind: .notice, message: "Model Qwen 3.8 is loaded and ready.")
                    BTBanner(kind: .warn, message: "Memory is running low; a smaller model may be faster.")
                    BTBanner(kind: .error, message: "Could not reach the model server. Retrying.", onDismiss: { })
                }
            }
            section("Empty state") {
                BTPanel {
                    BTEmptyState(icon: .chat, title: "No conversations yet", message: "Start a chat and it will appear here.") {
                        Button("New chat") { }.buttonStyle(.btPrimary)
                    }
                }
            }
            section("Markdown") { BTPanel { MarkdownView(sampleMarkdown) } }
            section("Diff") { DiffView(sampleDiff) }
        }
        .padding(32)
        .frame(maxWidth: 880, alignment: .leading)
        .frame(maxWidth: .infinity)

        if flat { content } else { ScrollView { content } }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            BTSectionHeader(eyebrow: "Design", title: "Black Team", intro: "Private AI. Total control.")
            BTSegmented(options: ThemeSetting.allCases.map { ($0.rawValue, $0.label) }, selection: $stored)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).btEyebrow(theme)
            content()
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(BTFont.mono(10)).foregroundStyle(theme.muted)
    }

    private func avatar(_ name: String, _ state: AvatarState) -> some View {
        VStack(spacing: 8) { AgentAvatar(state: state); caption(name) }
    }
}
