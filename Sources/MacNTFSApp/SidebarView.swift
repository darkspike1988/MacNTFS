import SwiftUI
import AppKit
import NTFSCore

struct SidebarView: View {
    @ObservedObject var driveManager: DriveManager
    @State private var showingCreateImageSheet: Bool = false

    var body: some View {
        List(selection: $driveManager.selectedDriveID) {
            let realDrives = driveManager.drives.filter {
                !$0.isDiskImage &&
                !$0.busProtocol.contains("Disk Image") &&
                !$0.modelName.contains("Disk Image")
            }

            Section("Laufwerke") {
                ForEach(realDrives) { drive in
                    NavigationLink(value: drive.id) {
                        DriveRow(drive: drive)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MacNTFS")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { driveManager.refreshDrives() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Laufwerksliste aktualisieren")
            }

            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button(action: openImagePicker) {
                        Label("Vorhandenes Image öffnen...", systemImage: "folder")
                    }
                    Button(action: { showingCreateImageSheet = true }) {
                        Label("Neues NTFS-Image erstellen...", systemImage: "plus.circle")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .help("Disk-Image verwalten")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button(action: { showingCreateImageSheet = true }) {
                    Label("Neues NTFS-Image...", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.ntfsBlue)
                .controlSize(.regular)

                Button(action: openImagePicker) {
                    Label("Image öffnen...", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(12)
        }
        .sheet(isPresented: $showingCreateImageSheet) {
            CreateImageSheet(driveManager: driveManager)
        }
    }

    private func openImagePicker() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.data]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.prompt = "Image öffnen"

        if openPanel.runModal() == .OK, let url = openPanel.url {
            driveManager.loadDiskImage(at: url)
        }
    }
}

// MARK: - Create NTFS Disk Image Sheet

struct CreateImageSheet: View {
    @ObservedObject var driveManager: DriveManager
    @Environment(\.dismiss) private var dismiss

    @State private var volumeName: String = "NTFS_IMAGE"
    @State private var selectedSizeMB: UInt64 = 50
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?

    let sizeOptions: [(String, UInt64)] = [
        ("20 MB (Kompakt)", 20),
        ("50 MB (Standard)", 50),
        ("100 MB", 100),
        ("250 MB", 250),
        ("500 MB", 500),
        ("1 GB", 1024),
        ("2 GB", 2048),
        ("5 GB", 5120)
    ]

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 28))
                    .foregroundStyle(AppTheme.ntfsBlue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Neues NTFS Disk-Image")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("Erstellt eine virtuelle NTFS-Festplattendatei (.img)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Volume-Name:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    TextField("NTFS_IMAGE", text: $volumeName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Kapazität:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Picker("", selection: $selectedSizeMB) {
                        ForEach(sizeOptions, id: \.1) { opt in
                            Text(opt.0).tag(opt.1)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Dateisystem:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Windows NTFS 3.1 • Automatisch formatiert mit 4 KB Clustergröße")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Button("Abbrechen") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Erstellen & Speichern...") {
                    promptSaveAndCreate()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.ntfsBlue)
                .disabled(isCreating)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func promptSaveAndCreate() {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "\(volumeName).img"
        savePanel.prompt = "Image erstellen"
        savePanel.canCreateDirectories = true

        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            createImage(at: targetURL)
        }
    }

    private func createImage(at url: URL) {
        isCreating = true
        errorMessage = nil

        let totalBytes = selectedSizeMB * 1024 * 1024
        let name = volumeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "NTFS_IMAGE" : volumeName

        Task {
            do {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: totalBytes)
                try handle.close()

                let dev = try FileBlockDevice(path: url.path, writable: true)
                try NTFSFormatter.format(
                    device: dev,
                    options: .init(volumeName: name, clusterSize: 4096)
                )

                await MainActor.run {
                    self.isCreating = false
                    self.driveManager.loadDiskImage(at: url)
                    self.dismiss()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Fehler beim Erstellen: \(error.localizedDescription)"
                    self.isCreating = false
                }
            }
        }
    }
}

struct DriveRow: View {
    let drive: DiscoveredDrive

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: drive.isDiskImage ? "doc.zipper" : (drive.isSystemDisk ? "apple.logo" : (drive.isNTFS ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")))
                .foregroundStyle(drive.isNTFS ? AppTheme.ntfsBlue : .secondary)
                .font(.system(size: 18))

            VStack(alignment: .leading, spacing: 2) {
                Text(drive.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(drive.totalCapacity), countStyle: .file))
                    Text("•")
                    Text(drive.fileSystemName.components(separatedBy: " ").first ?? "Volume")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if drive.isSystemDisk {
                Text("macOS")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.1))
                    .foregroundStyle(.primary)
                    .clipShape(Capsule())
            } else if drive.isNTFS {
                Text("NTFS")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(AppTheme.ntfsBlue.opacity(0.15))
                    .foregroundStyle(AppTheme.ntfsBlue)
                    .clipShape(Capsule())
            } else {
                Text(drive.fileSystemName.components(separatedBy: " ").first ?? "Volume")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
            }

            if drive.isDirty {
                Circle()
                    .fill(AppTheme.warningOrange)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
    }
}
