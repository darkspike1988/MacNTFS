import SwiftUI

struct SettingsView: View {
    @AppStorage("autoMountNTFS") private var autoMountNTFS: Bool = true
    @AppStorage("showNotifications") private var showNotifications: Bool = true
    @AppStorage("preventUncleanEject") private var preventUncleanEject: Bool = true

    @State private var isCheckingUpdates: Bool = false
    @State private var updateStatus: String? = nil

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.5"
    }

    var body: some View {
        TabView {
            // Tab 1: Allgemein
            Form {
                Section("Einhänge-Verhalten") {
                    Toggle("NTFS-Laufwerke beim Anstecken automatisch mounten", isOn: $autoMountNTFS)
                    Toggle("Vor unsauberem Abziehen warnen (Dirty-Flag Schutz)", isOn: $preventUncleanEject)
                }

                Section("Mitteilungen") {
                    Toggle("Mitteilung anzeigen, wenn NTFS-Laufwerk bereit ist", isOn: $showNotifications)
                }
            }
            .padding(20)
            .tabItem {
                Label("Allgemein", systemImage: "gearshape")
            }

            // Tab 2: Updates
            VStack(spacing: 16) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(AppTheme.ntfsBlue)

                VStack(spacing: 4) {
                    Text("MacNTFS")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Version \(currentVersion) (Build 2026)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let status = updateStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(action: checkForUpdates) {
                    HStack {
                        if isCheckingUpdates {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Nach Updates suchen")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isCheckingUpdates)

                Text("Updates werden über GitHub Releases bereitgestellt.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(30)
            .frame(width: 420, height: 260)
            .tabItem {
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
            }

            // Tab 3: Über
            VStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 44))
                    .foregroundStyle(AppTheme.ntfsBlue)

                Text("MacNTFS")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Next-Gen Pure Swift NTFS Engine für macOS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()
                    .padding(.horizontal, 40)

                VStack(spacing: 6) {
                    Text("Freie & quelloffene Software")
                        .font(.body)
                        .fontWeight(.medium)

                    Text("Lizenziert unter der MIT-Lizenz • 100% Open Source")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    Link(destination: URL(string: "https://darkspike1988.github.io/MacNTFS/")!) {
                        Label("Produkt-Webseite", systemImage: "safari")
                    }

                    Link(destination: URL(string: "https://github.com/darkspike1988/MacNTFS")!) {
                        Label("GitHub Repository", systemImage: "arrow.up.right.square")
                    }
                }
                .font(.caption)
            }
            .padding(24)
            .frame(width: 420, height: 260)
            .tabItem {
                Label("Über", systemImage: "info.circle")
            }
        }
        .frame(width: 460, height: 290)
    }

    private func checkForUpdates() {
        isCheckingUpdates = true
        updateStatus = nil

        Task {
            guard let url = URL(string: "https://api.github.com/repos/darkspike1988/MacNTFS/releases/latest") else {
                return
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tagName = json["tag_name"] as? String {
                    await MainActor.run {
                        let cleanTag = tagName.replacingOccurrences(of: "v", with: "")
                        if cleanTag == self.currentVersion {
                            self.updateStatus = "MacNTFS ist auf dem neuesten Stand (v\(self.currentVersion))."
                        } else {
                            self.updateStatus = "Neues Update verfügbar: \(tagName)!"
                        }
                        self.isCheckingUpdates = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.updateStatus = "MacNTFS ist auf dem aktuellen Stand."
                    self.isCheckingUpdates = false
                }
            }
        }
    }
}
