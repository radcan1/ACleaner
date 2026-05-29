import SwiftUI
import AppKit

struct StartupManagerView: View {
    @StateObject private var scanner = StartupScanner()
    @State private var itemToDelete: StartupItem? = nil
    @State private var searchText = ""
    @AccessibilityFocusState private var focusedAfterScan: Bool

    private var filtered: [StartupItem] {
        guard !searchText.isEmpty else { return scanner.items }
        return scanner.items.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.detail.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if scanner.isScanning {
                scanningView
            } else if scanner.items.isEmpty {
                emptyView
            } else {
                listView
            }
        }
        .onAppear { scanner.scan() }
        .alert("Remove Item", isPresented: Binding(
            get:  { itemToDelete != nil },
            set:  { if !$0 { itemToDelete = nil } }
        )) {
            Button("Move to Trash", role: .destructive) {
                if let item = itemToDelete { scanner.delete(item: item) }
                itemToDelete = nil
            }
            Button("Cancel", role: .cancel) { itemToDelete = nil }
        } message: {
            Text("Move \"\(itemToDelete?.name ?? "")\" to the Trash? The launch agent plist file will be removed.")
        }
        .alert("Error", isPresented: Binding(
            get:  { scanner.errorMessage != nil },
            set:  { if !$0 { scanner.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { scanner.errorMessage = nil }
        } message: {
            Text(scanner.errorMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Startup Manager")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .accessibilityLabel("Search startup items")
            Button {
                scanner.scan()
                announce("Scanning startup items.")
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Refresh list")
            .disabled(scanner.isScanning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Scanning

    private var scanningView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .accessibilityLabel("Scanning startup items")
            Text("Scanning\u{2026}")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Empty

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text("No startup items found.")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityFocused($focusedAfterScan)
        .onAppear { focusedAfterScan = true }
    }

    // MARK: List

    private var listView: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryBar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groupedKinds, id: \.self) { kind in
                        let kindItems = filtered.filter { $0.kind == kind }
                        if !kindItems.isEmpty {
                            sectionHeader(kind)
                            ForEach(kindItems) { item in
                                itemRow(item)
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .accessibilityLabel("Startup items list")
        }
    }

    private var groupedKinds: [StartupItemKind] {
        [.loginItem, .userAgent, .systemAgent, .systemDaemon]
    }

    private var summaryBar: some View {
        let total = filtered.count
        let enabled = filtered.filter { $0.isEnabled }.count
        return Text("\(total) item\(total == 1 ? "" : "s")  •  \(enabled) enabled")
            .font(.callout)
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .accessibilityLabel("\(total) startup items, \(enabled) enabled")
    }

    private func sectionHeader(_ kind: StartupItemKind) -> some View {
        let count = filtered.filter { $0.kind == kind }.count
        return HStack {
            Text(kind.rawValue.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Text("(\(count))")
                .font(.caption)
                .foregroundColor(.secondary)
            if kind == .systemAgent || kind == .systemDaemon {
                Text("Read only")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(4)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.rawValue), \(count) items\(kind == .systemAgent || kind == .systemDaemon ? ", read only" : "")")
        .accessibilityAddTraits(.isHeader)
    }

    private func itemRow(_ item: StartupItem) -> some View {
        HStack(spacing: 12) {
            // Icon
            iconView(for: item)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            // Name + detail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .fontWeight(.medium)
                Text(item.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Delete button (user agents only)
            if item.canDelete {
                Button {
                    itemToDelete = item
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(item.name)")
            }

            // Toggle
            if item.canToggle {
                Toggle("", isOn: Binding(
                    get: { item.isEnabled },
                    set: { _ in scanner.toggle(item: item) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(item.isEnabled
                    ? "Disable \(item.name)"
                    : "Enable \(item.name)")
                .accessibilityHint(item.isEnabled
                    ? "Currently enabled. Toggle to disable at next login."
                    : "Currently disabled. Toggle to enable at next login.")
            } else {
                Text("System")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
                    .accessibilityLabel("System item, cannot be changed")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(item))
    }

    private func rowAccessibilityLabel(_ item: StartupItem) -> String {
        var parts = [item.name, item.detail, item.kind.rawValue]
        parts.append(item.isEnabled ? "enabled" : "disabled")
        if !item.canToggle { parts.append("system item, cannot be changed") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func iconView(for item: StartupItem) -> some View {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.detail) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: iconName(for: item.kind))
                .font(.system(size: 22))
                .foregroundColor(.secondary)
        }
    }

    private func iconName(for kind: StartupItemKind) -> String {
        switch kind {
        case .loginItem:    return "person.crop.circle"
        case .userAgent:    return "gearshape"
        case .systemAgent:  return "server.rack"
        case .systemDaemon: return "lock.shield"
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }
}
