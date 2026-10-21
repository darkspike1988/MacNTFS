import SwiftUI
import NTFSCore

struct DriveDetailView: View {
    let drive: DiscoveredDrive
    @ObservedObject var driveManager: DriveManager

    @State private var showingBrowser: Bool = false
    @State private var showingFormatSheet: Bool = false
    @State private var healthReport: NTFSHealthReport?
    @State private var isVerifying: Bool = false
    @State private var isRepairing: Bool = false
    @State private var repairStatusMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Hero Header
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [AppTheme.ntfsBlue.opacity(0.85), AppTheme.ntfsBlue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 72, height: 72)
                            .shadow(color: AppTheme.ntfsBlue.opacity(0.35), radius: 8, x: 0, y: 4)

                        Image(systemName: drive.isDiskImage ? "doc.zipper" : "externaldrive.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(drive.name)
                                .font(.title)
                                .fontWeight(.bold)

                            if drive.isNTFS {
                                Text("NTFS")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(AppTheme.ntfsBlue.opacity(0.15))
                                    .foregroundStyle(AppTheme.ntfsBlue)
                                    .clipShape(Capsule())
                            }

                            if drive.isDirty {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                    Text("Unclean Unmount")
                                }
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AppTheme.warningOrange.opacity(0.15))
                                .foregroundStyle(AppTheme.warningOrange)
                                .clipShape(Capsule())
                            } else {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.seal.fill")
                                    Text("Clean")
                                }
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AppTheme.successGreen.opacity(0.15))
                                .foregroundStyle(AppTheme.successGreen)
                                .clipShape(Capsule())
                            }
                        }

                        Text(drive.devicePath)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Action Buttons
                    HStack(spacing: 10) {
                        Button(action: { showingBrowser = true }) {
                            Label("Durchsuchen", systemImage: "folder.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.ntfsBlue)

                        Button(action: { showingFormatSheet = true }) {
                            Label("Formatieren...", systemImage: "eraser.line.dashed")
                        }
                        .buttonStyle(.bordered)

                        if let mount = drive.mountPoint {
                            Button(action: { openInFinder(path: mount) }) {
                                Label("Finder", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.bottom, 8)

                // Storage Capacity Card (macOS Apple Style Gauge)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Speicherbelegung")
                            .font(.headline)
                        Spacer()
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(drive.usedSpace), countStyle: .file)) von \(ByteCountFormatter.string(fromByteCount: Int64(drive.totalCapacity), countStyle: .file)) verwendet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 12)

                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [AppTheme.ntfsBlue, Color.blue],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(12, geo.size.width * CGFloat(drive.usagePercentage)), height: 12)
                        }
                    }
                    .frame(height: 12)

                    HStack(spacing: 16) {
                        HStack(spacing: 6) {
                            Circle().fill(AppTheme.ntfsBlue).frame(width: 8, height: 8)
                            Text("Belegt: \(ByteCountFormatter.string(fromByteCount: Int64(drive.usedSpace), countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Circle().fill(Color.primary.opacity(0.15)).frame(width: 8, height: 8)
                            Text("Frei: \(ByteCountFormatter.string(fromByteCount: Int64(drive.freeSpace), countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .appleCardStyle()

                // Information Grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    // Card 1: Volume Parameters
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Dateisystem-Details", systemImage: "info.circle")
                            .font(.headline)

                        Divider()

                        DetailRow(label: "Format", value: "Windows NT File System (NTFS)")
                        DetailRow(label: "Clustergröße", value: "\(drive.clusterSize / 1024) KB (\(drive.clusterSize) Bytes)")
                        DetailRow(label: "Seriennummer", value: drive.serialNumber)
                        DetailRow(label: "Zugriff", value: drive.isReadOnly ? "Nur Lesen" : "Lesen & Schreiben (Nativ)")
                    }
                    .appleCardStyle()

                    // Card 2: Integrity & State (Tuxera Maintenance feature)
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Erste Hilfe & Integrität", systemImage: "shield.checkered")
                            .font(.headline)

                        Divider()

                        DetailRow(
                            label: "Dirty Flag",
                            value: drive.isDirty ? "Aktiv (Unsauber getrennt)" : "Sauber ausgehängt",
                            color: drive.isDirty ? AppTheme.warningOrange : AppTheme.successGreen
                        )
                        DetailRow(label: "Treiber-Architektur", value: "Native FSKit User-Space")
                        DetailRow(label: "SIP / Kernel Extension", value: "Keine KEXT nötig (100% sicher)")

                        HStack(spacing: 10) {
                            Button(action: runIntegrityCheck) {
                                HStack(spacing: 4) {
                                    if isVerifying {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "wrench.and.screwdriver")
                                    }
                                    Text("Überprüfen")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isVerifying || isRepairing)

                            if drive.isDirty || (healthReport != nil && !healthReport!.repairsAvailable.isEmpty) {
                                Button(action: runRepair) {
                                    HStack(spacing: 4) {
                                        if isRepairing {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "sparkles")
                                        }
                                        Text("Volume reparieren")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(AppTheme.ntfsBlue)
                                .controlSize(.small)
                                .disabled(isVerifying || isRepairing)
                            }
                        }
                    }
                    .appleCardStyle()
                }

                // Diagnostics Report Output
                if let report = healthReport {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: report.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(report.isHealthy ? AppTheme.successGreen : AppTheme.warningOrange)
                            Text(report.isHealthy ? "Diagnose abgeschlossen: Dateisystem ist vollkommen intakt." : "Diagnose abgeschlossen: Auffälligkeiten festgestellt.")
                                .font(.headline)
                        }

                        Divider()

                        HStack(spacing: 24) {
                            Label("Haupt-Bootsektor: \(report.bootSectorValid ? "OK" : "Fehlerhaft")", systemImage: report.bootSectorValid ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(report.bootSectorValid ? Color.secondary : Color.red)
                            Label("Backup-Bootsektor: \(report.backupBootSectorValid ? "OK" : "Fehlerhaft")", systemImage: report.backupBootSectorValid ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(report.backupBootSectorValid ? Color.secondary : Color.red)
                            Label("MFT 0 ($MFT): \(report.mft0Valid ? "OK" : "Fehlerhaft")", systemImage: report.mft0Valid ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(report.mft0Valid ? Color.secondary : Color.red)
                        }
                        .font(.caption)

                        if !report.issues.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(report.issues, id: \.self) { issue in
                                    Text("• \(issue)")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.warningOrange)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .appleCardStyle()
                }

                if let repairMsg = repairStatusMessage {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(AppTheme.successGreen)
                        Text(repairMsg)
                            .font(.subheadline)
                        Spacer()
                    }
                    .appleCardStyle()
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showingBrowser) {
            FileBrowserSheet(drive: drive, volume: driveManager.getNTFSVolume(for: drive))
        }
        .sheet(isPresented: $showingFormatSheet) {
            FormatVolumeSheet(drive: drive, driveManager: driveManager)
        }
    }

    private func openInFinder(path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func runIntegrityCheck() {
        isVerifying = true
        repairStatusMessage = nil

        Task {
            do {
                let dev = try FileBlockDevice(path: drive.devicePath, writable: false)
                let rep = try NTFSVolumeChecker.verify(device: dev)
                await MainActor.run {
                    self.healthReport = rep
                    self.isVerifying = false
                }
            } catch {
                await MainActor.run {
                    self.repairStatusMessage = "Diagnose fehlgeschlagen: \(error.localizedDescription)"
                    self.isVerifying = false
                }
            }
        }
    }

    private func runRepair() {
        isRepairing = true
        repairStatusMessage = nil

        Task {
            do {
                let dev = try FileBlockDevice(path: drive.devicePath, writable: true)
                let actions = try NTFSVolumeChecker.repair(device: dev)
                await MainActor.run {
                    self.repairStatusMessage = actions.joined(separator: " ")
                    self.isRepairing = false
                    self.healthReport = nil
                    self.driveManager.refreshDrives()
                }
            } catch {
                await MainActor.run {
                    self.repairStatusMessage = "Reparatur fehlgeschlagen: \(error.localizedDescription)"
                    self.isRepairing = false
                }
            }
        }
    }
}

// MARK: - Format Volume Sheet (Apple Disk Utility HIG style)

struct FormatVolumeSheet: View {
    let drive: DiscoveredDrive
    @ObservedObject var driveManager: DriveManager
    @Environment(\.dismiss) private var dismiss

    @State private var volumeName: String = ""
    @State private var selectedClusterSize: UInt32 = 4096
    @State private var isFormatting: Bool = false
    @State private var errorMessage: String?
    @State private var showingConfirmation: Bool = false

    let clusterOptions: [(String, UInt32)] = [
        ("512 Bytes", 512),
        ("1024 Bytes (1 KB)", 1024),
        ("2048 Bytes (2 KB)", 2048),
        ("4096 Bytes (4 KB - Standard)", 4096),
        ("8192 Bytes (8 KB)", 8192),
        ("16384 Bytes (16 KB)", 16384),
        ("32768 Bytes (32 KB)", 32768),
        ("65536 Bytes (64 KB)", 65536)
    ]

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "eraser.line.dashed")
                    .font(.system(size: 28))
                    .foregroundStyle(AppTheme.ntfsBlue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Volume formatieren")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("Initialisiert '\(drive.name)' als NTFS-Dateisystem")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Warning Banner
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Achtung: Datenverlust")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("Beim Formatieren werden alle vorhandenen Daten auf diesem Volume unwiderruflich gelöscht.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Form
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name des Volumes:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    TextField("UNTITLED", text: $volumeName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Clustergröße (Zuordnungseinheit):")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Picker("", selection: $selectedClusterSize) {
                        ForEach(clusterOptions, id: \.1) { opt in
                            Text(opt.0).tag(opt.1)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Dateisystem-Format:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Windows NT File System (NTFS 3.1) • Voll kompatibel mit Windows & Mac")
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

            // Bottom Buttons
            HStack {
                Button("Abbrechen") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: { showingConfirmation = true }) {
                    if isFormatting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Formatiere...")
                        }
                    } else {
                        Text("Formatieren")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isFormatting)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            self.volumeName = drive.name
        }
        .confirmationDialog(
            "Möchtest du '\(drive.name)' wirklich löschen und in NTFS formatieren?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Formatieren & Daten löschen", role: .destructive) {
                performFormat()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Dateien auf '\(drive.devicePath)' gehen dauerhaft verloren.")
        }
    }

    private func performFormat() {
        isFormatting = true
        errorMessage = nil

        let targetName = volumeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "UNTITLED" : volumeName
        let cluster = selectedClusterSize

        Task {
            do {
                let dev = try FileBlockDevice(path: drive.devicePath, writable: true)
                try NTFSFormatter.format(
                    device: dev,
                    options: .init(volumeName: targetName, clusterSize: cluster)
                )
                await MainActor.run {
                    self.isFormatting = false
                    self.driveManager.refreshDrives()
                    self.dismiss()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Fehler beim Formatieren: \(error.localizedDescription)"
                    self.isFormatting = false
                }
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(color)
        }
    }
}
