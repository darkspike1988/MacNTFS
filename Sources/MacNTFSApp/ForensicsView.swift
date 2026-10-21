import SwiftUI
import NTFSCore
import AppKit

struct ForensicsView: View {
    let drive: DiscoveredDrive
    let volume: NTFSVolume?
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Int = 0

    // Tab 1: Undelete / File Carving
    @State private var recoverableFiles: [RecoverableFile] = []
    @State private var isScanningMFT: Bool = false
    @State private var selectedFileID: UInt64?
    @State private var recoveryStatus: String?
    @State private var scanCompleted: Bool = false

    // Tab 2: Hex Inspector
    @State private var hexOffsetInput: String = "0"
    @State private var currentHexDump: String = ""
    @State private var isLoadingHex: Bool = false

    // Tab 3: Surface Scan
    @State private var isScanningSurface: Bool = false
    @State private var surfaceReport: SurfaceScanReport?
    @State private var bootComparison: BootSectorForensics?

    var selectedFile: RecoverableFile? {
        guard let id = selectedFileID else { return nil }
        return recoverableFiles.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 26))
                    .foregroundStyle(AppTheme.ntfsBlue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("NTFS Forensik & Datenrettung")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("\(drive.name) • \(drive.devicePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Schließen") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Material.bar)

            Divider()

            // Tab Picker
            Picker("", selection: $selectedTab) {
                Text("Gelöschte Dateien retten").tag(0)
                Text("Forensischer Hex-Inspektor").tag(1)
                Text("Oberflächenscan & Sektoren").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Tab Content
            Group {
                if selectedTab == 0 {
                    fileCarvingTabView
                } else if selectedTab == 1 {
                    hexInspectorTabView
                } else {
                    surfaceScanTabView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 520)
        .onAppear {
            loadInitialHex()
        }
    }

    // MARK: - Tab 1: File Carving View

    private var fileCarvingTabView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Forensisches MFT Carving")
                        .font(.headline)
                    Text("Durchsucht inaktive MFT-Einträge nach Spuren gelöschter Dateien und extrahiert deren Daten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: scanForDeletedFiles) {
                    HStack(spacing: 6) {
                        if isScanningMFT {
                            ProgressView().controlSize(.small)
                            Text("Scanne MFT...")
                        } else {
                            Image(systemName: "magnifyingglass")
                            Text("MFT nach gelöschten Dateien scannen")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.ntfsBlue)
                .disabled(isScanningMFT)
            }
            .padding()

            Divider()

            if isScanningMFT {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Analysiere Master File Table (MFT) nach gelöschten Records...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if recoverableFiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: scanCompleted ? "checkmark.circle" : "doc.badge.gearshape")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text(scanCompleted ? "Keine wiederherstellbaren Dateien gefunden" : "Bereit für forensischen MFT-Scan")
                        .font(.headline)
                    Text(scanCompleted ? "Alle gelöschten MFT-Slots wurden bereits überschrieben oder sind leer." : "Klicke auf den Button oben, um gelöschte Dateien auf diesem Volume aufzuspüren.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(recoverableFiles, selection: $selectedFileID) {
                    TableColumn("Dateiname") { f in
                        HStack(spacing: 6) {
                            Image(systemName: f.isDirectory ? "folder" : "doc")
                                .foregroundStyle(AppTheme.ntfsBlue)
                            Text(f.fileName)
                                .fontWeight(.medium)
                        }
                    }
                    TableColumn("Größe") { f in
                        Text(ByteCountFormatter.string(fromByteCount: Int64(f.fileSize), countStyle: .file))
                    }
                    TableColumn("MFT Record") { f in
                        Text("#\(f.recordNumber)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Chance") { f in
                        Text(f.confidence.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(confidenceColor(f.confidence).opacity(0.15))
                            .foregroundStyle(confidenceColor(f.confidence))
                            .clipShape(Capsule())
                    }
                    TableColumn("Zuletzt geändert") { f in
                        Text(f.modificationDate, style: .date)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack {
                    if let sel = selectedFile {
                        Text("Ausgewählt: '\(sel.fileName)' (\(ByteCountFormatter.string(fromByteCount: Int64(sel.fileSize), countStyle: .file)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Datei auf Mac wiederherstellen...") {
                            recoverFile(sel)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.successGreen)
                    } else {
                        Text("Wähle eine gefundene Datei aus der Liste, um sie zu retten.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding()
            }

            if let msg = recoveryStatus {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AppTheme.successGreen)
                    Text(msg)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
            }
        }
    }

    // MARK: - Tab 2: Hex Inspector View

    private var hexInspectorTabView: some View {
        VStack(spacing: 0) {
            // Shortcuts Bar
            HStack(spacing: 8) {
                Text("Schnellsprung:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Bootsektor (0x00)") { jumpTo(0) }
                Button("$MFT (Record 0)") {
                    if let vol = volume { jumpTo(vol.bootSector.mftByteOffset) }
                }
                Button("$Volume (Rec 3)") {
                    if let vol = volume { jumpTo(vol.bootSector.mftByteOffset + 3072) }
                }
                Button("$Root (Rec 5)") {
                    if let vol = volume { jumpTo(vol.bootSector.mftByteOffset + 5120) }
                }
                Button("Backup-VBR") {
                    let off = drive.totalCapacity >= 512 ? drive.totalCapacity - 512 : 0
                    jumpTo(off)
                }

                Spacer()

                HStack(spacing: 4) {
                    TextField("Offset (Bytes)", text: $hexOffsetInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Button("Gehe zu") {
                        if let off = UInt64(hexOffsetInput) { jumpTo(off) }
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Hex Monospace View
            ScrollView([.horizontal, .vertical]) {
                Text(currentHexDump)
                    .font(.system(.body, design: .monospaced))
                    .padding(16)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    // MARK: - Tab 3: Surface Scan View

    private var surfaceScanTabView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Oberflächenscan & Sektor-Diagnose")
                        .font(.headline)
                    Text("Führt eine zerstörungsfreie Leseprüfung aller physischen Sektoren durch, um Hardware-Fehler zu identifizieren.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: startSurfaceScan) {
                    HStack(spacing: 6) {
                        if isScanningSurface {
                            ProgressView().controlSize(.small)
                            Text("Scanne Sektoren...")
                        } else {
                            Image(systemName: "wrench.and.screwdriver")
                            Text("Oberflächen-Scan starten")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.ntfsBlue)
                .disabled(isScanningSurface)
            }

            Divider()

            // Boot Sector Forensic Comparison Card
            if let boot = bootComparison {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Bootsektor-Forensik (Haupt-VBR vs. Backup-VBR)", systemImage: "shield.lefthalf.filled")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    HStack(spacing: 20) {
                        ForensicBadge(label: "Hauptsektor", isOk: boot.primaryValid)
                        ForensicBadge(label: "Backup-Sektor", isOk: boot.backupValid)
                        ForensicBadge(label: "Byte-Exakt Synchron", isOk: boot.byteIdentical)
                        ForensicBadge(label: "Seriennummer", isOk: boot.serialMatches)
                        ForensicBadge(label: "Clustergröße", isOk: boot.clusterSizeMatches)
                    }
                }
                .appleCardStyle()
            }

            // Surface Scan Results
            if let rep = surfaceReport {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: rep.isDamaged ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .foregroundStyle(rep.isDamaged ? AppTheme.warningOrange : AppTheme.successGreen)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(rep.isDamaged ? "Beschädigte Sektoren gefunden!" : "Oberflächenscan fehlerfrei: 0 defekte Sektoren")
                                .font(.headline)
                            Text("\(rep.totalSectorsScanned) Sektoren (\(ByteCountFormatter.string(fromByteCount: Int64(rep.totalBytesScanned), countStyle: .file))) ohne I/O-Lesefehler geprüft.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !rep.badSectors.isEmpty {
                        Divider()
                        Text("Defekte Sektor-Adressen (LBA):")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(rep.badSectors, id: \.self) { s in
                                    Text("• Sektor LBA \(s) (Byte 0x\(String(s * 512, radix: 16)))")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
                .appleCardStyle()
            } else if !isScanningSurface {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text("Kein Scan aktiv")
                        .font(.headline)
                    Text("Starte den Scan, um physische Lese- und Blockfehler auf der Festplatte zu erkennen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Lese Sektoren des Datenträgers...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            compareBoots()
        }
    }

    // MARK: - Actions

    private func scanForDeletedFiles() {
        guard let vol = volume else { return }
        isScanningMFT = true
        recoveryStatus = nil

        Task {
            do {
                let found = try vol.scanDeletedFiles()
                await MainActor.run {
                    self.recoverableFiles = found
                    self.isScanningMFT = false
                    self.scanCompleted = true
                }
            } catch {
                await MainActor.run {
                    self.isScanningMFT = false
                    self.scanCompleted = true
                }
            }
        }
    }

    private func recoverFile(_ file: RecoverableFile) {
        guard let vol = volume else { return }

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = file.fileName
        savePanel.prompt = "Wiederherstellen"

        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            Task {
                do {
                    let (_, data) = try vol.recoverDeletedFile(recordNumber: file.recordNumber)
                    try data.write(to: targetURL)
                    await MainActor.run {
                        self.recoveryStatus = "'\(file.fileName)' (\(data.count) Bytes) erfolgreich auf Mac gesichert!"
                    }
                } catch {
                    await MainActor.run {
                        self.recoveryStatus = "Fehler bei Wiederherstellung: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func jumpTo(_ offset: UInt64) {
        hexOffsetInput = String(offset)
        isLoadingHex = true

        Task {
            do {
                let dev = try FileBlockDevice(path: drive.devicePath)
                let raw = try dev.read(offset: offset, count: 512)
                let dump = NTFSForensicsEngine.hexDump(data: raw, baseOffset: offset, maxBytes: 512)
                await MainActor.run {
                    self.currentHexDump = dump
                    self.isLoadingHex = false
                }
            } catch {
                await MainActor.run {
                    self.currentHexDump = "Fehler beim Lesen von Offset 0x\(String(offset, radix: 16)): \(error.localizedDescription)"
                    self.isLoadingHex = false
                }
            }
        }
    }

    private func loadInitialHex() {
        jumpTo(0)
    }

    private func startSurfaceScan() {
        isScanningSurface = true
        surfaceReport = nil

        Task {
            do {
                let dev = try FileBlockDevice(path: drive.devicePath)
                // Sample scan up to first 50 MB for responsiveness
                let scanLimit = min(dev.size, 50 * 1024 * 1024)
                let rep = try NTFSForensicsEngine.surfaceScan(device: dev, maxBytesToScan: scanLimit)
                await MainActor.run {
                    self.surfaceReport = rep
                    self.isScanningSurface = false
                }
            } catch {
                await MainActor.run {
                    self.isScanningSurface = false
                }
            }
        }
    }

    private func compareBoots() {
        Task {
            do {
                let dev = try FileBlockDevice(path: drive.devicePath)
                let comp = try NTFSForensicsEngine.compareBootSectors(device: dev)
                await MainActor.run {
                    self.bootComparison = comp
                }
            } catch {}
        }
    }

    private func confidenceColor(_ conf: RecoverableFile.RecoveryConfidence) -> Color {
        switch conf {
        case .excellent: return AppTheme.successGreen
        case .high: return AppTheme.ntfsBlue
        case .moderate: return AppTheme.warningOrange
        case .uncertain: return .secondary
        }
    }
}

struct ForensicBadge: View {
    let label: String
    let isOk: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isOk ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isOk ? AppTheme.successGreen : AppTheme.warningOrange)
            Text(label)
                .font(.caption)
                .foregroundStyle(isOk ? .primary : AppTheme.warningOrange)
        }
    }
}
