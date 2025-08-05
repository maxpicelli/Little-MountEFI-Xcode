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
}

// MARK: - EFI Manager
class EFIManager: ObservableObject {
    @Published var partitions: [EFIPartition] = []
    @Published var isScanning = false
    @Published var errorMessage: String?
    @Published var showingAlert = false
    
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
        // Detectar EFI de boot
        let bootEFI = detectBootEFI()
        
        // Obter todas as partições EFI
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
            // Método 1: NVRAM
            let bootEFIUUID = try executeShellCommand("nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path | sed 's/.*GPT,\\([^,]*\\),.*/\\1/'")
            let bootEFI = try executeShellCommand("diskutil info '\(bootEFIUUID)' | awk -F': ' '/Device Identifier/ {print $2}' | xargs")
            return bootEFI
        } catch {
            do {
                // Método 2: Disco do sistema
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
            mountPoint: mountPoint
        )
    }
    
    func toggleMount(partition: EFIPartition) {
        let command = partition.isMounted ? "diskutil unmount" : "diskutil mount"
        let fullCommand = "\(command) '\(partition.diskName)'"
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Usar osascript para executar com privilégios administrativos
                let script = """
                do shell script "\(fullCommand)" with administrator privileges
                """
                
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                
                try process.run()
                process.waitUntilExit()
                
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        // Sucesso - atualizar lista após delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.scanEFIPartitions()
                            
                            // Se montou com sucesso, abrir no Finder e trazer janela para frente
                            if !partition.isMounted {
                                self.openInFinder(diskName: partition.diskName)
                                self.bringWindowToFront()
                            }
                        }
                    } else {
                        // Erro - ler mensagem do pipe
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
    
    // NOVA FUNÇÃO: Trazer janela para frente
    private func bringWindowToFront() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
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

// MARK: - Views
struct ContentView: View {
    @StateObject private var efiManager = EFIManager()
    @State private var selectedPartition: EFIPartition?
    
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
        // MUDANÇA: Tamanho menor da janela
        .frame(minWidth: 550, minHeight: 450)
        // MUDANÇA: Cores personalizadas da janela
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.05, green: 0.1, blue: 0.2),
                    Color(red: 0.1, green: 0.15, blue: 0.25)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .preferredColorScheme(.dark)
    }
    
    private var headerView: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "externaldrive.fill")
                    // MUDANÇA: Fonte maior
                    .font(.title)
                    .foregroundColor(.cyan)
                
                Text("Little MountEFI")
                    // MUDANÇA: Fonte maior
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Spacer()
                
                Text("Max.1974")
                    // MUDANÇA: Fonte maior
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            Text("Gerenciador de Partições EFI")
                // MUDANÇA: Fonte maior
                .font(.headline)
                .foregroundColor(.cyan.opacity(0.8))
                .padding(.bottom, 8)
        }
        // MUDANÇA: Cor de fundo personalizada
        .background(Color.black.opacity(0.3))
    }
    
    private var legendView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 20) {
                legendItem("🔹", "EFI Boot")
                legendItem("◈", "Bootloader")
                Spacer()
            }
            
            HStack(spacing: 20) {
                legendItem("✅", "Montada")
                legendItem("🔘", "Interna")
                legendItem("🟡", "USB/Ext")
                Spacer()
            }
        }
        // MUDANÇA: Fonte maior
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        // MUDANÇA: Cor de fundo personalizada
        .background(Color.black.opacity(0.2))
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
                .tint(.cyan)
            
            Text("Escaneando partições EFI...")
                // MUDANÇA: Fonte maior
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
                // MUDANÇA: Fonte maior
                .font(.title2)
                .foregroundColor(.white)
            
            Text("Verifique se há discos conectados com partições EFI")
                // MUDANÇA: Fonte maior
                .font(.headline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            
            Button("Tentar Novamente") {
                efiManager.scanEFIPartitions()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // MUDANÇA: Cor personalizada do botão
            .tint(.cyan)
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
                        onToggleMount: { efiManager.toggleMount(partition: partition) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
    
    private var footerView: some View {
        HStack {
            Button("Atualizar") {
                efiManager.scanEFIPartitions()
            }
            .buttonStyle(.bordered)
            .disabled(efiManager.isScanning)
            // MUDANÇA: Cor personalizada
            .tint(.cyan)
            
            Spacer()
            
            if let selected = selectedPartition {
                Button(selected.isMounted ? "Desmontar" : "Montar") {
                    efiManager.toggleMount(partition: selected)
                }
                .buttonStyle(.borderedProminent)
                .disabled(efiManager.isScanning)
                // MUDANÇA: Cor personalizada
                .tint(.cyan)
            }
            
            Button("Sair") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
            // MUDANÇA: Cor vermelha para sair
            .tint(.red)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // MUDANÇA: Cor de fundo personalizada
        .background(Color.black.opacity(0.3))
    }
}

struct PartitionRowView: View {
    let partition: EFIPartition
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleMount: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Status and Boot markers
            HStack(spacing: 4) {
                Text(partition.statusIcon)
                    // MUDANÇA: Fonte maior
                    .font(.title2)
                
                Text(partition.bootMarker)
                    // MUDANÇA: Fonte maior
                    .font(.title2)
                    .frame(width: 20)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(partition.diskName)
                        // MUDANÇA: Fonte maior
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                    
                    if partition.isReadOnly {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.orange)
                            // MUDANÇA: Fonte maior
                            .font(.callout)
                    }
                    
                    Spacer()
                }
                
                Text(partition.displayName)
                    // MUDANÇA: Fonte maior
                    .font(.headline)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    if partition.isBootEFI {
                        Text("BOOT")
                            // MUDANÇA: Fonte maior
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.cyan.opacity(0.3))
                            .foregroundColor(.cyan)
                            .cornerRadius(6)
                    }
                    
                    if partition.hasBootloader {
                        Text("BOOTLOADER")
                            // MUDANÇA: Fonte maior
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.purple.opacity(0.3))
                            .foregroundColor(.purple)
                            .cornerRadius(6)
                    }
                }
                
                Text(partition.isInternal ? "Interno" : "Externo")
                    // MUDANÇA: Fonte maior
                    .font(.callout)
                    .foregroundColor(.gray)
            }
            
            Button(partition.isMounted ? "Desmontar" : "Montar") {
                onToggleMount()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            // MUDANÇA: Cor personalizada
            .tint(.cyan)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                // MUDANÇA: Cor de fundo personalizada
                .fill(isSelected ? Color.cyan.opacity(0.2) : Color.black.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.cyan : Color.gray.opacity(0.3), lineWidth: 2)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
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
        // MUDANÇA: Configurações da janela para trazer para frente
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

// MARK: - Extensions
extension NSColor {
    static let controlBackgroundColor = NSColor.controlBackgroundColor
}
