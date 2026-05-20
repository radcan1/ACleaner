import SwiftUI

struct PermissionsView: View {
    let onContinue: () -> Void

    @State private var fdaGranted = PermissionsChecker.hasFullDiskAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────
            HStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Privacy Permissions")
                        .font(.title2).fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)
                    Text("Grant the permissions below once and ACleaner will run without repeated prompts each time you use it.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 20)

            Divider()

            // ── Permission rows ──────────────────────────────────────
            VStack(spacing: 12) {
                PermissionRow(
                    icon: "internaldrive",
                    title: "Full Disk Access",
                    detail: fdaGranted
                        ? "Granted — Disk Detective and Clean Uninstall can scan all folders freely."
                        : "Not granted — needed by Disk Detective and Clean Uninstall to scan Library folders, caches, and leftover files without per-folder prompts.",
                    granted: fdaGranted,
                    actionLabel: fdaGranted ? nil : "Open System Settings"
                ) {
                    PermissionsChecker.openFullDiskAccessSettings()
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)

            Divider()

            // ── Footer ───────────────────────────────────────────────
            HStack {
                if !fdaGranted {
                    Button("Check Again") {
                        fdaGranted = PermissionsChecker.hasFullDiskAccess
                    }
                    .accessibilityHint("Re-checks whether Full Disk Access has been granted in System Settings.")
                }

                Spacer()

                Button(fdaGranted ? "Continue" : "Continue Without Full Access") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityHint(fdaGranted
                    ? "Opens ACleaner."
                    : "Opens ACleaner without Full Disk Access. You may see repeated permission prompts while using the tools.")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .frame(width: 520)
        // Re-check whenever the view appears (e.g. user switched back from System Settings)
        .onAppear {
            fdaGranted = PermissionsChecker.hasFullDiskAccess
        }
    }
}

// MARK: - Permission row

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let actionLabel: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(granted ? .green : .orange)
                        .accessibilityHidden(true)
                    Text(title)
                        .fontWeight(.medium)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if let label = actionLabel {
                Button(label) { action() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(granted ? "Granted." : "Not granted.") \(detail)")
    }
}
