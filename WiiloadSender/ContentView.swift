import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var selectedFileURL: URL?
    @State private var selectedFileData: Data?
    @State private var selectedFileName: String = ""
    @State private var selectedFileSize: Int = 0

    @State private var isShowingFileImporter = false
    @State private var isShowingSettings = false

    @State private var isScanning = false
    @State private var isShowingURLPrompt = false
    @State private var isDownloading = false
    @State private var urlText = ""
    @State private var status: SendStatus = .idle
    @State private var errorMessage: String?

    private let client = WiiloadClient()

    enum SendStatus: Equatable {
        case idle
        case connecting
        case sending(Double)
        case success
        case failure

        var isBusy: Bool {
            switch self {
            case .connecting, .sending: return true
            default: return false
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Wii / Wii U Address") {
                    TextField("e.g. 192.168.1.42", text: $settings.lastIPAddress)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        Task { await scan() }
                    } label: {
                        HStack {
                            if isScanning { ProgressView().padding(.trailing, 6) }
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text(isScanning ? "Scanning…" : "Scan for Wii")
                        }
                    }
                    .disabled(isScanning || status.isBusy)
                }

                Section("File") {
                    Button {
                        isShowingFileImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "doc.badge.plus")
                            VStack(alignment: .leading) {
                                Text(selectedFileName.isEmpty ? "Choose .dol, .elf, .rpx or .zip File" : selectedFileName)
                                    .foregroundStyle(selectedFileName.isEmpty ? .secondary : .primary)
                                if selectedFileSize > 0 {
                                    Text(byteCountFormatted(selectedFileSize) + (settings.arguments.isEmpty ? "" : " · " + settings.arguments))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }

                    Button {
                        isShowingURLPrompt = true
                    } label: {
                        HStack {
                            if isDownloading { ProgressView().padding(.trailing, 6) }
                            Image(systemName: "link")
                            Text(isDownloading ? "Downloading…" : "Load from URL")
                        }
                    }
                    .disabled(isDownloading || status.isBusy)
                }

                Section {
                    Button {
                        Task { await sendFile() }
                    } label: {
                        HStack {
                            Spacer()
                            if status.isBusy {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(sendButtonTitle)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!canSend)
                } footer: {
                    statusFooter
                }
            }
            .navigationTitle("Wiiload Sender")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
                    .environmentObject(settings)
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [UTType.dolFile, UTType.elfFile, UTType.data, UTType.item],
                allowsMultipleSelection: false
            ) { result in
                handleFileImportResult(result)
            }
            .onOpenURL { url in
                if url.isFileURL {
                    loadFile(from: url)
                } else {
                    Task { await downloadFile(from: url) }
                }
            }
            .alert("Load from URL", isPresented: $isShowingURLPrompt) {
                TextField("https://example.com/app.dol", text: $urlText)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Download") {
                    let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                          scheme == "http" || scheme == "https" else {
                        errorMessage = "Enter a valid http(s) URL."
                        status = .failure
                        return
                    }
                    Task { await downloadFile(from: url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a link to a .dol, .elf, .rpx or .zip file.")
            }
        }
        .preferredColorScheme(settings.appearance.colorScheme)
    }

    private var canSend: Bool {
        selectedFileData != nil
            && !settings.lastIPAddress.trimmingCharacters(in: .whitespaces).isEmpty
            && !status.isBusy
            && !isScanning
            && !isDownloading
            && (1...65535).contains(settings.port)
    }

    private var sendButtonTitle: String {
        switch status {
        case .idle, .failure: return "Send to Wii"
        case .connecting: return "Connecting…"
        case .sending(let fraction): return "Sending… \(Int(fraction * 100))%"
        case .success: return "Sent!"
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        switch status {
        case .success:
            Label("File sent successfully.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure:
            Label(errorMessage ?? "Something went wrong.", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        default:
            Text("Make sure the Homebrew Channel (or another wiiload listener) is running on your Wii and connected to the same network.")
        }
    }

    private func handleFileImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            loadFile(from: url)
        case .failure(let error):
            errorMessage = error.localizedDescription
            status = .failure
        }
    }

    private func loadFile(from url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()
            if !["dol", "elf", "rpx", "zip"].contains(ext) {
                errorMessage = "Selected file isn't a .dol, .elf, .rpx or .zip, but it'll be sent as-is."
            } else {
                errorMessage = nil
            }
            selectedFileData = data
            selectedFileURL = url
            selectedFileName = url.lastPathComponent
            selectedFileSize = data.count
            status = .idle
        } catch {
            errorMessage = "Couldn't read that file: \(error.localizedDescription)"
            status = .failure
        }
    }

    private func sendFile() async {
        guard let data = selectedFileData else { return }
        errorMessage = nil
        status = .connecting

        do {
            try await client.send(fileData: data, fileName: selectedFileName, arguments: settings.arguments,
                                  to: settings.lastIPAddress, port: UInt16(settings.port)) { progress in
                Task { @MainActor in
                    switch progress {
                    case .connecting:
                        status = .connecting
                    case .sending(let fraction):
                        status = .sending(fraction)
                    case .finished:
                        status = .success
                    }
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                status = .failure
            }
        }
    }

    private func downloadFile(from url: URL) async {
        isDownloading = true
        errorMessage = nil
        status = .idle
        defer { isDownloading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            var name = response.suggestedFilename ?? url.lastPathComponent
            if name.isEmpty || name == "/" { name = "download.dol" }
            let ext = (name as NSString).pathExtension.lowercased()
            errorMessage = ["dol", "elf", "rpx", "zip"].contains(ext) ? nil
                : "Downloaded file isn't a .dol, .elf, .rpx or .zip, but it'll be sent as-is."
            selectedFileData = data
            selectedFileURL = url
            selectedFileName = name
            selectedFileSize = data.count
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
            status = .failure
        }
    }

    private func scan() async {
        isScanning = true
        errorMessage = nil
        status = .idle
        let found = await WiiloadClient.scan(port: UInt16(settings.port))
        isScanning = false
        if let found {
            settings.lastIPAddress = found
        } else {
            errorMessage = "No Wii found on this network. Make sure the Homebrew Channel is waiting for a connection and Local Network access is allowed."
            status = .failure
        }
    }

    private func byteCountFormatted(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Arguments", text: $settings.arguments)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", value: $settings.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                } header: {
                    Text("Wiiload")
                } footer: {
                    Text("Arguments are passed to the program (space-separated). Default port is 4299.")
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension UTType {
    static let dolFile = UTType(exportedAs: "com.quatricsoftware.wiiloadsender.dol")
    static let elfFile = UTType(exportedAs: "com.quatricsoftware.wiiloadsender.elf")
}

#Preview {
    ContentView()
        .environmentObject(AppSettings())
}
