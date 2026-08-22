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
                }

                Section("File") {
                    Button {
                        isShowingFileImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "doc.badge.plus")
                            VStack(alignment: .leading) {
                                Text(selectedFileName.isEmpty ? "Choose .dol or .elf File" : selectedFileName)
                                    .foregroundStyle(selectedFileName.isEmpty ? .secondary : .primary)
                                if selectedFileSize > 0 {
                                    Text(byteCountFormatted(selectedFileSize))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
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
                loadFile(from: url)
            }
        }
        .preferredColorScheme(settings.appearance.colorScheme)
    }

    private var canSend: Bool {
        selectedFileData != nil
            && !settings.lastIPAddress.trimmingCharacters(in: .whitespaces).isEmpty
            && !status.isBusy
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
            if ext != "dol" && ext != "elf" {
                errorMessage = "Selected file isn't a .dol or .elf, but it'll be sent as-is."
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
            try await client.send(fileData: data, to: settings.lastIPAddress) { progress in
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
    static let dolFile = UTType(exportedAs: "com.larsenv.wiiloadsender.dol")
    static let elfFile = UTType(exportedAs: "com.larsenv.wiiloadsender.elf")
}

#Preview {
    ContentView()
        .environmentObject(AppSettings())
}
