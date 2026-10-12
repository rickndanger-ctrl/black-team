import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import BlackTeamKit

// "PRIVATE ACCESS / Take Camp with you." and "PHONE APP / Install Black Team" on Servers & access
// (Companion.jsx `PhonePairing`, MobileApp.jsx; the states and wording of PhoneSettings.jsx).

/// A QR code drawn on this Mac with Core Image: the pairing link never goes to a QR service.
struct QRCodeView: View {
    let text: String
    var side: CGFloat = 200
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.white)
            if let image = QRCodeView.image(text, points: side - 16) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: side - 16, height: side - 16)
            }
        }
        .frame(width: side, height: side)
        .accessibilityLabel("Pairing code for your phone")
    }

    /// Error correction M, drawn in whole pixels so every square is sharp.
    static func image(_ text: String, points: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let modules = output.extent.width
        let scale = max(1, (points * 2 / modules).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width / 2, height: scaled.extent.height / 2))
    }
}

struct PhoneAccessCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var phone: PhoneModel
    @Environment(\.btTheme) private var theme

    var body: some View {
        WorkCard(label: "PRIVATE ACCESS", title: "Take Camp with you.") {
            if let text = phone.error { BTBanner(kind: .error, message: text) { phone.error = nil }.padding(.top, 12) }
            else if let text = phone.notice { BTBanner(kind: .notice, message: text) { phone.notice = nil }.padding(.top, 12) }
            switch phone.phase {
            case .checking:
                CardText("Looking for Tailscale on this Mac\u{2026}")
            case .notInstalled:
                steps
                CardText("Tailscale is not installed on this Mac. Install it, sign in with the same account you use on your phone, then check again.")
                HStack(spacing: 10) {
                    Button("Get Tailscale") { model.openHelp("tailscale") }.buttonStyle(.btPrimary)
                    Button("Check again") { Task { await phone.refresh(model) } }.buttonStyle(.btSecondary).disabled(phone.busy)
                }.padding(.top, 14)
            case .signedOut:
                steps
                CardText("Tailscale is installed but not connected. Open Tailscale and sign in with the same account you use on your phone, then check again.")
                Button("Check again") { Task { await phone.refresh(model) } }.buttonStyle(.btPrimary).disabled(phone.busy).padding(.top, 14)
            case .off:
                steps
                Button(phone.busy ? "Connecting\u{2026}" : "Enable private phone access") { Task { await phone.enable(model) } }
                    .buttonStyle(.btPrimary).disabled(phone.busy).padding(.top, 14)
            case .problem:
                CardText(phone.problemText)
                HStack(spacing: 10) {
                    Button(phone.busy ? "Connecting\u{2026}" : "Try again") { Task { await phone.enable(model) } }.buttonStyle(.btPrimary).disabled(phone.busy)
                    Button("Turn off phone access") { Task { await phone.disable(model) } }.buttonStyle(.btSecondary).disabled(phone.busy)
                }.padding(.top, 14)
            case .ready:
                CardText("Scan this with your phone while it is connected to your Tailscale account. The code pairs that phone with this computer; share it only with your own devices.")
                if let link = phone.link {
                    HStack(alignment: .center, spacing: 22) {
                        QRCodeView(text: link)
                        VStack(alignment: .leading, spacing: 14) {
                            FieldText(text: link, mono: true, monoSize: 10.5).accessibilityLabel("Pairing link")
                            HStack(spacing: 10) {
                                Button(phone.copied ? "Link copied" : "Copy pairing link") { phone.copy() }.buttonStyle(.btSecondary)
                                Button("Reset phone pairing") { phone.confirmReset = true }.buttonStyle(.btSecondary).disabled(phone.busy)
                            }
                        }
                    }
                    .padding(.top, 20)
                }
                CardText("This computer must stay powered on and awake. Chats are saved here; running requests continue after you close the app.").padding(.top, 8)
                Button("Turn off phone access") { phone.confirmOff = true }.buttonStyle(.btQuiet).disabled(phone.busy).padding(.top, 12)
            }
        }
        .alert("Unpair every phone?", isPresented: $phone.confirmReset) {
            Button("Reset phone pairing", role: .destructive) { Task { await phone.reset(model) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You will scan a new code to pair again.") }
        .alert("Turn off phone access?", isPresented: $phone.confirmOff) {
            Button("Turn off phone access", role: .destructive) { Task { await phone.disable(model) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Phones stop reaching this Mac, and Black Team removes its private Tailscale route. Other Tailscale routes are not touched.") }
    }

    /// PhoneSettings.jsx's three steps.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardText("Your phone controls the same local model and agent on this Mac. Keep the Mac awake and Black Team open.")
            CardText("1. Connect Tailscale. Install it on your Mac and phone, and sign in with the same account.", small: true)
            CardText("2. Enable private access. Black Team finds this Mac and your account for you.", small: true)
            CardText("3. Scan and open. Scan the QR code with your phone camera. No separate phone app is needed.", small: true)
        }
    }
}

/// MobileApp.jsx without notifications: how to put the web app on a Home Screen.
struct PhoneAppCard: View {
    var body: some View {
        WorkCard(label: "PHONE APP", title: "Install Black Team") {
            CardText("On iPhone: open this private address in Safari, tap Share \u{2192} Add to Home Screen, and enable Open as Web App. Keep Tailscale connected.")
            CardText("Tasks run on your computer while the phone is closed. Reconnect to review progress. The computer must stay awake.")
        }
    }
}
