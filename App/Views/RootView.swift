import SwiftUI

struct RootView: View {
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        TabView {
            Tab("Dictate", systemImage: "mic") { DictateView().tint(.ink) }
            Tab("Settings", systemImage: "slider.horizontal.3") { SettingsView().tint(.ink) }
        }
        .tint(.ink)
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
    }
}

/// Large circular control for Record and Stop.
struct RecordButton: View {
    var symbol: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.onAccent)
                .frame(width: 88, height: 88)
                .background(Color.accentInk, in: Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

struct PressScale: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.1 : 0.15), value: configuration.isPressed)
    }
}

/// Full-width primary action, 50 pt high.
struct PrimaryButton: View {
    var title: String
    var symbol: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text(title).fontWeight(.semibold) } icon: { if let symbol { Image(systemName: symbol) } }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(Color.onAccent)
                .background(Color.accentInk, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressScale())
    }
}

enum DictationLocale {
    static var name: String {
        Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier
    }
}
