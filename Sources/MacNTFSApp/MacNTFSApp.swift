import SwiftUI

@main
struct MacNTFSApp: App {
    @StateObject private var driveManager = DriveManager()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("MacNTFS", id: "main") {
            ContentView(driveManager: driveManager)
                .frame(minWidth: 800, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
        }

        MenuBarExtra("MacNTFS", systemImage: "externaldrive.fill") {
            VStack(alignment: .leading, spacing: 6) {
                Text("MacNTFS")
                    .font(.headline)

                Divider()

                let ntfsDrives = driveManager.drives.filter { $0.isNTFS }
                if ntfsDrives.isEmpty {
                    Text("Keine NTFS-Laufwerke angeschlossen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ntfsDrives) { drive in
                        HStack {
                            Image(systemName: drive.isDirty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(drive.isDirty ? .orange : .green)
                            Text(drive.name)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(drive.totalCapacity), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                Button("MacNTFS öffnen...") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.title.contains("MacNTFS") }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                }

                Button("Laufwerke aktualisieren") {
                    driveManager.refreshDrives()
                }

                Divider()

                Button("Beenden") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}
