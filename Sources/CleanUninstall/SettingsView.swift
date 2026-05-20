import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Start CleanUninstall at login", isOn: Binding(
                    get: { state.loginItemEnabled },
                    set: { state.setLoginItem($0) }
                ))
                .accessibilityHint("When on, CleanUninstall launches automatically when you log in and keeps watching the Trash.")
            } header: {
                Text("Startup")
                    .accessibilityAddTraits(.isHeader)
            }

            Section {
                Toggle("Watch the Trash for applications", isOn: Binding(
                    get: { state.watchEnabled },
                    set: { state.setWatch($0) }
                ))
                .accessibilityHint("Turn off to temporarily stop watching without quitting the app.")
            } header: {
                Text("Detection")
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .padding()
    }
}
