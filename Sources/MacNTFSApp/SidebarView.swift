import SwiftUI
import AppKit

struct SidebarView: View {
    @ObservedObject var driveManager: DriveManager

    var body: some View {
        List(selection: $driveManager.selectedDriveID) {
            let ntfsDrives = driveManager.drives.filter { $0.isNTFS && !$0.isDiskImage }
            if !ntfsDrives.isEmpty {
                Section("NTFS Volumes") {
                    ForEach(ntfsDrives) { drive in
                        NavigationLink(value: drive.id) {
                            DriveRow(drive: drive)
                        }
                    }
                }
            }

            let diskImages = driveManager.drives.filter { $0.isDiskImage }
            if !diskImages.isEmpty {
                Section("Disk Images") {
                    ForEach(diskImages) { drive in
                        NavigationLink(value: drive.id) {
                            DriveRow(drive: drive)
                        }
                    }
                }
            }

            let otherDrives = driveManager.drives.filter { !$0.isNTFS && !$0.isDiskImage }
            if !otherDrives.isEmpty {
                Section("Andere Laufwerke") {
                    ForEach(otherDrives) { drive in
                        NavigationLink(value: drive.id) {
                            DriveRow(drive: drive)
                        }
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
                Button(action: openImagePicker) {
                    Image(systemName: "plus.circle")
                }
                .help("NTFS Disk-Image öffnen (.img, .raw)")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: openImagePicker) {
                Label("Disk Image öffnen...", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(12)
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

struct DriveRow: View {
    let drive: DiscoveredDrive

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: drive.isDiskImage ? "doc.zipper" : "externaldrive.fill")
                .foregroundStyle(drive.isNTFS ? AppTheme.ntfsBlue : .secondary)
                .font(.system(size: 18))

            VStack(alignment: .leading, spacing: 2) {
                Text(drive.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(ByteCountFormatter.string(fromByteCount: Int64(drive.totalCapacity), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if drive.isDirty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.warningOrange)
                    .font(.caption)
            } else if drive.isNTFS {
                Text("NTFS")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(AppTheme.ntfsBlue.opacity(0.12))
                    .foregroundStyle(AppTheme.ntfsBlue)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}
