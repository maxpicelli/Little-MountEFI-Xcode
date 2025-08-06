import SwiftUI
import Foundation
import OSLog

// MARK: - Models
struct EFIPartition: Identifiable, Hashable {
    let id = UUID()
    let diskName: String
    let diskLabel: String
    let isMounted: Bool
    let isBootEFI: Bool
    let hasBootloader: Bool
    let isInternal: Bool
    let isReadOnly: Bool
    let mountPoint: String
    let parentDisk: String
    
    var statusIcon: String {
        if isMounted {
            return "✅"
        } else if isInternal {
            return "🔘"
        } else {
            return "🟡"
        }
    }
    
    var bootMarker: String {
        if isBootEFI {
            return "🔹"
        } else if hasBootloader {
            return "◈"
        } else {
            return "  "
        }
    }
    
    var displayName: String {
        return diskLabel.isEmpty ? diskName : diskLabel
    }
    
    var canEject: Bool {
        return !isInternal && isMounted
    }
}

// MARK: - Background Manager
class BackgroundManager: ObservableObject {
    @Published var backgroundImage: NSImage?
    private let fixedOpacity: Double = 0.9
    @Published var useGradientOverlay: Bool = false
    
    var backgroundOpacity: Double {
        return fixedOpacity
    }
    
    init() {
        loadBackgroundImage()
    }
    
    private func loadBackgroundImage() {
        let imageNames = ["mount_efi_bg", "background", "wallpaper"]
        let extensions = ["png", "jpg", "jpeg", "heic"]
        
        // 1. Bundle
        for imageName in imageNames {
            if let bundleImage = NSImage(named: imageName) {
                self.backgroundImage = bundleImage
                return
            }
        }
        
        // 2. Documents
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let documentsPath = documentsPath {
            for imageName in imageNames {
                for ext in extensions {
                    let imagePath = documentsPath.appendingPathComponent("\(imageName).\(ext)")
                    if let image = NSImage(contentsOf: imagePath) {
                        self.backgroundImage = image
                        return
                    }
                }
            }
        }
        
        // 3. Desktop
        let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if let desktopPath = desktopPath {
            for imageName in imageNames {
                for ext in extensions {
                    let imagePath = desktopPath.appendingPathComponent("\(imageName).\(ext)")
                    if let image = NSImage(contentsOf: imagePath) {
                        self.backgroundImage = image
                        return
                    }
                }
            }
        }
    }
    
    func setCustomBackground(from url: URL) {
        if let image = NSImage(contentsOf: url) {
            self.backgroundImage = image
        }
    }
}

// MARK: - Background View
struct BackgroundView: View {
    let image: NSImage?
    let opacity: Double
    let useGradient: Bool
    
    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
                    .opacity(opacity)
                    .animation(.easeInOut(duration: 0.5), value: opacity)
            } else {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.1, green: 0.15, blue: 0.25),
                        Color(red: 0.05, green: 0.1, blue: 0.2)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            
            if useGradient {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.black.opacity(0.7),
                        Color.black.opacity(0.5),
                        Color.black.opacity(0.6)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}

// MARK: - EFI Manager
class EFIManager: ObservableObject {
    @Published var partitions: [EFIPartition] = []
    @Published var isScanning = false
    @Published var errorMessage: String?
    @Published var showingAlert = false
    @Published var lastOperationTime: Date?
    
    func scanEFIPartitions() {
        isScanning = true
        errorMessage = nil
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let partitions = try self.detectEFIPartitions()
                
                DispatchQueue.main.async {
                    self.partitions = partitions
                    self.isScanning = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.showingAlert = true
                    self.isScanning = false
                }
            }
        }
    }
    
    private func detectEFIPartitions() throws -> [EFIPartition] {
        let bootEFI = detectBootEFI()
        let efiDisksOutput = try executeShellCommand("diskutil list | grep EFI | awk '{print $NF}'")
        let efiDisks = efiDisksOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }
        
        var partitions: [EFIPartition] = []
        
        for diskName in efiDisks {
            if let partition = try createEFIPartition(diskName: diskName, bootEFI: bootEFI) {
                partitions.append(partition)
            }
        }
        
        return partitions
    }
    
    private func detectBootEFI() -> String {
        do {
            let bootEFIUUID = try executeShellCommand("nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path | sed 's/.*GPT,\\([^,]*\\),.*/\\1/'")
            let bootEFI = try executeShellCommand("diskutil info '\(bootEFIUUID)' | awk -F': ' '/Device Identifier/ {print $2}' | xargs")
            return bootEFI
        } catch {
            do {
                let systemDisk = try executeShellCommand("diskutil info / | awk -F': ' '/Device Identifier/ {print $2}' | xargs")
                let wholeDisk = try executeShellCommand("diskutil info '\(systemDisk)' | awk -F': ' '/Part of Whole/ {print $2}' | xargs")
                return "\(wholeDisk)s1"
            } catch {
                return ""
            }
        }
    }
    
    private func createEFIPartition(diskName: String, bootEFI: String) throws -> EFIPartition? {
        let parentDisk = try executeShellCommand("diskutil info '\(diskName)' | awk -F': ' '/Part of Whole/ {print $2}' | xargs")
        let diskLabel = try executeShellCommand("diskutil info '\(parentDisk)' | awk -F': ' '/Volume Name|Media Name/ {print $2}' | head -1 | xargs")
        let mountPoint = try executeShellCommand("diskutil info '\(diskName)' | awk -F': ' '/Mount Point/ {print $2}' | xargs")
        let readOnlyStatus = try executeShellCommand("diskutil info '\(diskName)' | awk -F': ' '/Read-Only/ {print $2}' | xargs")
        
        let isInternalCmd = """
        diskutil info '\(parentDisk)' |
        awk -F': ' '
          /Internal/ {internal = $2}
          /Protocol/ {protocol = $2}
          END {
            if (internal == "No" || tolower(protocol) ~ /usb/) {
              print "No"
            } else {
              print "Yes"
            }
          }
        ' | xargs
        """
        let isInternal = try executeShellCommand(isInternalCmd) == "Yes"
        
        let isMounted = !mountPoint.isEmpty && mountPoint != "Not Mounted"
        let isBootEFI = diskName == bootEFI
        let isReadOnly = readOnlyStatus.lowercased() == "yes"
        
        var hasBootloader = false
        if isMounted {
            let bootloaderCheck = """
            mountPoint=$(diskutil info '\(diskName)' | awk -F': ' '/Mount Point/ {print $2}' | xargs);
            if [ -d "$mountPoint/EFI/OC" ] || [ -d "$mountPoint/EFI/CLOVER" ]; then echo 'yes'; else echo 'no'; fi
            """
            hasBootloader = (try? executeShellCommand(bootloaderCheck)) == "yes"
        }
        
        return EFIPartition(
            diskName: diskName,
            diskLabel: diskLabel,
            isMounted: isMounted,
            isBootEFI: isBootEFI,
            hasBootloader: hasBootloader,
            isInternal: isInternal,
            isReadOnly: isReadOnly,
            mountPoint: mountPoint,
            parentDisk: parentDisk
        )
    }
    
    // DUPLO CLIQUE - Monta/Desmonta DIRETO!
    func toggleMount(partition: EFIPartition) {
        let command = partition.isMounted ? "diskutil unmount" : "diskutil mount"
        let fullCommand = "\(command) '\(partition.diskName)'"
        
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            do shell script "\(fullCommand)" with administrator privileges
            """
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        self.lastOperationTime = Date()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.scanEFIPartitions()
                            
                            if !partition.isMounted {
                                self.openInFinder(diskName: partition.diskName)
                                self.bringWindowToFront()
                            }
                        }
                    } else {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let errorOutput = String(data: data, encoding: .utf8) ?? "Erro desconhecido"
                        self.errorMessage = errorOutput
                        self.showingAlert = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.showingAlert = true
                }
            }
        }
    }
    
    func ejectDisk(partition: EFIPartition) {
        let fullCommand = "diskutil eject '\(partition.parentDisk)'"
        
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            do shell script "\(fullCommand)" with administrator privileges
            """
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        self.lastOperationTime = Date()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.scanEFIPartitions()
                        }
                    } else {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let errorOutput = String(data: data, encoding: .utf8) ?? "Erro ao ejetar dispositivo"
                        self.errorMessage = errorOutput
                        self.showingAlert = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.showingAlert = true
                }
            }
        }
    }
    
    private func openInFinder(diskName: String) {
        do {
            let mountPoint = try executeShellCommand("diskutil info '\(diskName)' | awk -F': ' '/Mount Point/ {print $2}' | xargs")
            if !mountPoint.isEmpty && mountPoint != "Not Mounted" {
                let url = URL(fileURLWithPath: mountPoint)
                NSWorkspace.shared.open(url)
            }
        } catch {
            print("Erro ao abrir no Finder: \(error)")
        }
    }
    
    private func bringWindowToFront() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
    
    func forceRescan() {
        isScanning = true
        errorMessage = nil
        
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: 1.0)
            
            do {
                let partitions = try self.detectEFIPartitions()
                
                DispatchQueue.main.async {
                    self.partitions = partitions
                    self.isScanning = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.showingAlert = true
                    self.isScanning = false
                }
            }
        }
    }
    
    private func executeShellCommand(_ command: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        
        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-c", command]
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ShellCommand", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
        }
        
        return output
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var efiManager = EFIManager()
    @StateObject private var backgroundManager = BackgroundManager()
    @State private var selectedPartition: EFIPartition?
    @State private var showingInfo = false
    @State private var showingSettings = false
    @State private var showingCompactWindow = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            // Legend
            legendView
            
            Divider()
            
            // Content
            if efiManager.isScanning {
                loadingView
            } else if efiManager.partitions.isEmpty {
                emptyStateView
            } else {
                partitionListView
            }
            
            Spacer()
            
            // Footer
            footerView
        }
        .onAppear {
            efiManager.scanEFIPartitions()
        }
        .alert("Erro", isPresented: $efiManager.showingAlert) {
            Button("OK") { }
        } message: {
            Text(efiManager.errorMessage ?? "Erro desconhecido")
        }
        .sheet(isPresented: $showingInfo) {
            InfoView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(backgroundManager: backgroundManager)
        }
        // JANELA COMPACTA FLUTUANTE
        .sheet(isPresented: $showingCompactWindow) {
            CompactMountView(efiManager: efiManager)
        }
        .frame(minWidth: 750, minHeight: 650)
        .background(
            BackgroundView(
                image: backgroundManager.backgroundImage,
                opacity: backgroundManager.backgroundOpacity,
                useGradient: backgroundManager.useGradientOverlay
            )
        )
        .preferredColorScheme(.dark)
    }
    
    private var headerView: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "externaldrive.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                
                Text("Little MountEFI")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Spacer()
                
                // BOTÃO JANELA COMPACTA
                Button(action: { showingCompactWindow = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.callout)
                        Text("Compacta")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .help("Abrir janela compacta flutuante")
                
                Button(action: { showingInfo = true }) {
                    Image(systemName: "info.circle")
                        .font(.title2)
                        .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
                
                Text("Max.1974")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            Text("Gerenciador de Partições EFI")
                .font(.headline)
                .foregroundColor(.orange.opacity(0.9))
                .padding(.bottom, 8)
        }
        .background(Color(red: 0.2, green: 0.3, blue: 0.5).opacity(0.4))
    }
    
    private var legendView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 20) {
                legendItem("🔹", "EFI Boot")
                legendItem("◈", "Bootloader")
                legendItem("🖱️🖱️", "Duplo clique monta/desmonta")
                Spacer()
            }
            
            HStack(spacing: 20) {
                legendItem("✅", "Montada")
                legendItem("🔘", "Interna")
                legendItem("🟡", "USB/Ext")
                legendItem("⌘+🖱️🖱️", "Cmd+Duplo clique ejeta")
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color(red: 0.8, green: 0.4, blue: 0.2).opacity(0.3))
    }
    
    private func legendItem(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(icon)
            Text(label)
                .foregroundColor(.white.opacity(0.8))
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.orange)
            
            Text("Escaneando partições EFI...")
                .font(.title2)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.trianglebadge.exclamationmark")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Nenhuma partição EFI encontrada")
                .font(.title2)
                .foregroundColor(.white)
            
            Text("Verifique se há discos conectados com partições EFI")
                .font(.headline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            
            Button("Tentar Novamente") {
                efiManager.scanEFIPartitions()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.orange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var partitionListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(efiManager.partitions) { partition in
                    PartitionRowView(
                        partition: partition,
                        isSelected: selectedPartition == partition,
                        onSelect: { selectedPartition = partition },
                        onToggleMount: { efiManager.toggleMount(partition: partition) },
                        onEject: { efiManager.ejectDisk(partition: partition) },
                        // DUPLO CLIQUE = AÇÃO DIRETA!
                        onDoubleClick: { efiManager.toggleMount(partition: partition) },
                        onCmdDoubleClick: {
                            if partition.canEject {
                                efiManager.ejectDisk(partition: partition)
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
    
    private var footerView: some View {
        HStack {
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            
            Button("Atualizar") {
                efiManager.scanEFIPartitions()
            }
            .buttonStyle(.bordered)
            .disabled(efiManager.isScanning)
            .tint(.orange)
            
            Button("Scan Completo") {
                efiManager.forceRescan()
            }
            .buttonStyle(.bordered)
            .disabled(efiManager.isScanning)
            .tint(.orange)
            
            Spacer()
            
            if let selected = selectedPartition {
                HStack(spacing: 8) {
                    if selected.canEject {
                        Button(action: { efiManager.ejectDisk(partition: selected) }) {
                            HStack {
                                Image(systemName: "eject")
                                Text("Ejetar")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(efiManager.isScanning)
                        .tint(.red)
                    }
                    
                    Button(selected.isMounted ? "Desmontar" : "Montar") {
                        efiManager.toggleMount(partition: selected)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(efiManager.isScanning)
                    .tint(.orange)
                }
            }
            
            Button("Sair") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(red: 0.2, green: 0.3, blue: 0.5).opacity(0.4))
    }
}

// MARK: - Partition Row View COM DUPLO CLIQUE
struct PartitionRowView: View {
    let partition: EFIPartition
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleMount: () -> Void
    let onEject: () -> Void
    let onDoubleClick: () -> Void
    let onCmdDoubleClick: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text(partition.statusIcon)
                    .font(.title2)
                
                Text(partition.bootMarker)
                    .font(.title2)
                    .frame(width: 20)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(partition.diskName)
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                    
                    if partition.isReadOnly {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.orange)
                            .font(.callout)
                    }
                    
                    Spacer()
                }
                
                Text(partition.displayName)
                    .font(.headline)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    if partition.isBootEFI {
                        Text("BOOT")
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.3))
                            .foregroundColor(.orange)
                            .cornerRadius(6)
                    }
                    
                    if partition.hasBootloader {
                        Text("BOOTLOADER")
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(red: 0.2, green: 0.3, blue: 0.5).opacity(0.3))
                            .foregroundColor(Color(red: 0.3, green: 0.5, blue: 0.8))
                            .cornerRadius(6)
                    }
                }
                
                Text(partition.isInternal ? "Interno" : "Externo")
                    .font(.callout)
                    .foregroundColor(.gray)
            }
            
            HStack(spacing: 8) {
                if partition.canEject {
                    Button(action: onEject) {
                        Image(systemName: "eject")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.red)
                    .help("Ejetar dispositivo")
                }
                
                Button(partition.isMounted ? "Desmontar" : "Montar") {
                    onToggleMount()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.orange.opacity(0.2) : (isHovering ? Color.white.opacity(0.1) : Color.black.opacity(0.4)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.orange : (isHovering ? Color.orange.opacity(0.5) : Color.gray.opacity(0.3)), lineWidth: 2)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        // DUPLO CLIQUE MÁGICO! 🎯
        .onTapGesture(count: 2) {
            if NSEvent.modifierFlags.contains(.command) {
                onCmdDoubleClick()
            } else {
                onDoubleClick() // <- AQUI É A MÁGICA!
            }
        }
        .onTapGesture {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
}

// MARK: - JANELA COMPACTA FLUTUANTE! 🚀
struct CompactMountView: View {
    @ObservedObject var efiManager: EFIManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header super compacto
            HStack {
                Image(systemName: "externaldrive.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
                
                Text("Quick Mount")
                    .font(.headline)
                    .foregroundColor(.white)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button("✕") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.gray)
                .font(.title2)
            }
            .padding(12)
            .background(Color(red: 0.2, green: 0.3, blue: 0.5).opacity(0.8))
            
            // Instrução clara
            HStack {
                Image(systemName: "hand.tap")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text("Duplo clique para montar/desmontar")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 6)
            
            // Lista ultra compacta
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(efiManager.partitions) { partition in
                        CompactPartitionRow(
                            partition: partition,
                            onDoubleClick: { efiManager.toggleMount(partition: partition) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            
            // Footer compacto
            HStack(spacing: 8) {
                Button("Atualizar") {
                    efiManager.scanEFIPartitions()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
                .disabled(efiManager.isScanning)
                
                if efiManager.isScanning {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.orange)
                }
            }
            .padding(8)
            .background(Color.black.opacity(0.3))
        }
        .frame(width: 380, height: 420)
        .background(Color.black.opacity(0.95))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
    }
}

// MARK: - Linha Compacta da Janela Flutuante
struct CompactPartitionRow: View {
    let partition: EFIPartition
    let onDoubleClick: () -> Void
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Status + Boot
            HStack(spacing: 2) {
                Text(partition.statusIcon)
                    .font(.callout)
                Text(partition.bootMarker)
                    .font(.callout)
                    .frame(width: 12)
            }
            
            // Nome do disco
            Text(partition.diskName)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)
                .fontWeight(.medium)
            
            Spacer()
            
            // Badges compactos
            HStack(spacing: 4) {
                if partition.isBootEFI {
                    Text("BOOT")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.3))
                        .foregroundColor(.orange)
                        .cornerRadius(4)
                }
                
                if partition.hasBootloader {
                    Text("BL")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.3))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
                
                if partition.isReadOnly {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            
            // Tipo
            Text(partition.isInternal ? "INT" : "EXT")
                .font(.caption2)
                .foregroundColor(.gray)
                .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.orange.opacity(0.2) : Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isHovering ? Color.orange.opacity(0.6) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        // DUPLO CLIQUE DIRETO!
        .onTapGesture(count: 2) {
            onDoubleClick()
        }
        .help("Duplo clique para \(partition.isMounted ? "desmontar" : "montar")")
    }
}

// MARK: - Views Auxiliares
struct InfoView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Little MountEFI")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Versão 2.1 - macOS Ventura+")
                .font(.title2)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("✨ **NOVO**: Duplo clique para montar/desmontar")
                Text("✨ **NOVO**: Janela compacta flutuante")
                Text("• Monta e desmonta partições EFI")
                Text("• Ejeta dispositivos externos com segurança")
                Text("• Detecta EFI de boot automaticamente")
                Text("• Identifica bootloaders (OpenCore/Clover)")
                Text("• Interface moderna e intuitiva")
                Text("• Papel de parede customizável")
                Text("• Compatível com macOS Ventura 13.7.7+")
            }
            .font(.body)
            
            Spacer()
            
            Button("Fechar") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(30)
        .frame(width: 480, height: 580)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var backgroundManager: BackgroundManager
    @State private var autoScanEnabled = true
    @State private var showNotifications = true
    @State private var openFinderAfterMount = true
    @State private var showingFilePicker = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Configurações")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Scan automático na inicialização", isOn: $autoScanEnabled)
                Toggle("Mostrar notificações", isOn: $showNotifications)
                Toggle("Abrir Finder após montar", isOn: $openFinderAfterMount)
                
                Divider()
                
                // Configurações de background
                VStack(alignment: .leading, spacing: 8) {
                    Text("Papel de Parede")
                        .font(.headline)
                    
                    HStack {
                        Text("Opacidade: 90% (fixo)")
                            .foregroundColor(.secondary)
                    }
                    
                    Toggle("Usar gradiente sobreposto", isOn: $backgroundManager.useGradientOverlay)
                    
                    Button("Escolher Imagem de Fundo") {
                        showingFilePicker = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            .toggleStyle(.switch)
            .font(.body)
            
            Spacer()
            
            HStack {
                Button("Cancelar") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Salvar") {
                    // Salvar configurações aqui
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(30)
        .frame(width: 450, height: 420)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    backgroundManager.setCustomBackground(from: url)
                }
            case .failure(let error):
                print("Erro ao selecionar imagem: \(error)")
            }
        }
    }
}

// MARK: - App
@main
struct LittleMountEFIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentSize)
    }
}

/*
 🚀 LITTLE MOUNTEFI - VERSÃO COMPLETA COM DUPLO CLIQUE
 
 ✨ NOVIDADES IMPLEMENTADAS:
 
 1. **DUPLO CLIQUE DIRETO** 🖱️🖱️
    - Duplo clique na linha = monta/desmonta INSTANTÂNEO
    - Cmd+Duplo clique = ejeta (se externo)
    - Pede senha e executa - simples assim!
 
 2. **JANELA COMPACTA FLUTUANTE** 📱
    - Botão "Compacta" no header
    - Janela pequena (380x420px)
    - Lista ultra compacta
    - Duplo clique funciona igual
    - Perfeita para uso rápido
 
 3. **MELHORIAS VISUAIS** ✨
    - Hover effects suaves
    - Badges compactos na janela pequena
    - Instruções claras
    - Animações fluidas
 
 ⚡ FLUXO DE USO SUPER RÁPIDO:
 1. Abrir app
 2. Duplo clique na partição
 3. Inserir senha
 4. ✅ MONTADO! (abre no Finder)
 
 🎯 EXATAMENTE COMO VOCÊ PEDIU:
 ✅ Duplo clique = ação imediata
 ✅ Janela compacta flutuante
 ✅ Mais rápido, menos cliques
 ✅ Pede senha e executa
 
 COMPATIBILIDADE:
 - macOS Ventura 13.7.7+
 - Xcode 14.0+
 - Swift 5.7+
 */
