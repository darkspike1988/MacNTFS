import SwiftUI
import NTFSCore
import UniformTypeIdentifiers

struct FileBrowserSheet: View {
    let drive: DiscoveredDrive
    let volume: NTFSVolume?
    @Environment(\.dismiss) private var dismiss

    @State private var currentPath: String = "/"
    @State private var items: [DirectoryItem] = []
    @State private var isLoading: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var errorMessage: String?
    @State private var selectedItemID: UInt64?
    @State private var statusMessage: String?

    var selectedItem: DirectoryItem? {
        guard let id = selectedItemID else { return nil }
        return items.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .font(.title2)
                    .foregroundStyle(AppTheme.ntfsBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.name)
                        .font(.headline)
                    Text("NTFS Dateibrowser • \(currentPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: importFile) {
                    Label("Datei hinzufügen...", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.ntfsBlue)

                Button("Schließen") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Material.bar)

            Divider()

            // Breadcrumbs Bar
            HStack(spacing: 6) {
                Button(action: { navigateTo("/") }) {
                    Image(systemName: "house.fill")
                }
                .buttonStyle(.plain)

                let parts = currentPath.split(separator: "/").map(String.init)
                ForEach(0..<parts.count, id: \.self) { idx in
                    Text("/")
                        .foregroundStyle(.tertiary)
                    Button(parts[idx]) {
                        let target = "/" + parts.prefix(idx + 1).joined(separator: "/")
                        navigateTo(target)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(idx == parts.count - 1 ? .primary : AppTheme.ntfsBlue)
                }

                Spacer()

                if currentPath != "/" {
                    Button(action: navigateUp) {
                        Label("Zurück", systemImage: "arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Content Area / Drop Target
            ZStack {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Lese NTFS-Verzeichnis...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(isDropTargeted ? AppTheme.ntfsBlue : .secondary.opacity(0.6))

                        Text("Ordner ist leer")
                            .font(.headline)

                        Text("Dateien aus dem Mac Finder hierher ziehen oder 'Datei hinzufügen' nutzen, um Daten direkt auf das NTFS-Volume zu schreiben.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(items, selection: $selectedItemID) {
                        TableColumn("Name") { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.isDirectory ? "folder.fill" : fileIcon(for: item.name))
                                    .foregroundStyle(item.isDirectory ? AppTheme.ntfsBlue : .secondary)
                                Text(item.name)
                                    .fontWeight(item.isDirectory ? .medium : .regular)
                            }
                        }
                        TableColumn("Größe") { item in
                            Text(item.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                        TableColumn("Geändert") { item in
                            Text(item.modificationDate, style: .date)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        if let selected = selectedItem {
                            if !selected.isDirectory {
                                Button("Auf Mac exportieren...") {
                                    exportFile(item: selected)
                                }
                            } else {
                                Button("Öffnen") {
                                    let newPath = currentPath == "/" ? "/\(selected.name)" : "\(currentPath)/\(selected.name)"
                                    navigateTo(newPath)
                                }
                            }
                        }
                    }
                }

                // Drop overlay highlight
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppTheme.ntfsBlue, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .background(AppTheme.ntfsBlue.opacity(0.06))
                        .padding(8)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDroppedProviders(providers)
            }

            // Bottom Bar / Feedback
            if let msg = statusMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(msg)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .onAppear {
            loadDirectory()
        }
    }

    private func navigateTo(_ path: String) {
        currentPath = path
        loadDirectory()
    }

    private func navigateUp() {
        var parts = currentPath.split(separator: "/").map(String.init)
        if !parts.isEmpty {
            parts.removeLast()
            let newPath = "/" + parts.joined(separator: "/")
            navigateTo(newPath)
        }
    }

    private func loadDirectory() {
        guard let vol = volume else {
            errorMessage = "Kein Zugriff auf das NTFS-Volume."
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let loaded = try vol.listDirectory(at: currentPath)
                await MainActor.run {
                    self.items = loaded
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func importFile() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = "Importieren"

        if openPanel.runModal() == .OK {
            for url in openPanel.urls {
                do {
                    try PrivilegedDiskBridge.writeFile(devicePath: drive.devicePath, fileURL: url, mountPoint: drive.mountPoint)
                } catch {
                    self.errorMessage = "Import fehlgeschlagen: \(error.localizedDescription)"
                    return
                }
            }
            self.statusMessage = "\(openPanel.urls.count) Datei(en) erfolgreich auf NTFS-Volume übertragen!"
            loadDirectory()
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        let targetDev = drive.devicePath
        let mount = drive.mountPoint

        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let fileURL = url else { return }
                Task {
                    do {
                        try PrivilegedDiskBridge.writeFile(devicePath: targetDev, fileURL: fileURL, mountPoint: mount)
                        await MainActor.run {
                            self.statusMessage = "'\(fileURL.lastPathComponent)' erfolgreich auf NTFS übertragen!"
                            self.loadDirectory()
                        }
                    } catch {
                        await MainActor.run {
                            self.errorMessage = "Fehler beim Schreiben von '\(fileURL.lastPathComponent)': \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
        return true
    }

    private func exportFile(item: DirectoryItem) {
        guard let vol = volume else { return }
        let fullPath = currentPath == "/" ? "/\(item.name)" : "\(currentPath)/\(item.name)"

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = item.name
        savePanel.canCreateDirectories = true

        savePanel.begin { result in
            if result == .OK, let targetURL = savePanel.url {
                Task {
                    do {
                        let data = try vol.readFile(at: fullPath)
                        try data.write(to: targetURL)
                        await MainActor.run {
                            self.statusMessage = "'\(item.name)' erfolgreich exportiert!"
                        }
                    } catch {
                        await MainActor.run {
                            self.errorMessage = "Export fehlgeschlagen: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic": return "photo"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "mp3", "wav", "m4a", "flac": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox"
        case "exe", "msi", "bat", "cmd": return "terminal"
        case "txt", "md", "json", "xml", "csv": return "doc.text"
        default: return "doc"
        }
    }
}
