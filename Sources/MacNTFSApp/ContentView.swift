import SwiftUI

struct ContentView: View {
    @ObservedObject var driveManager: DriveManager

    var body: some View {
        NavigationSplitView {
            SidebarView(driveManager: driveManager)
        } detail: {
            if let selectedID = driveManager.selectedDriveID,
               let drive = driveManager.drives.first(where: { $0.id == selectedID }) {
                DriveDetailView(drive: drive, driveManager: driveManager)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Kein Laufwerk ausgewählt")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Wähle ein NTFS-Volume in der Seitenleiste oder öffne ein Disk Image.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
