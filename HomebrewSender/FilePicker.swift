import UIKit
import UniformTypeIdentifiers

/// Presents the system document picker directly from UIKit, accepting any file.
/// Files are copied into the app's temp directory, so no security-scoped access is needed.
final class FilePicker: NSObject, UIDocumentPickerDelegate {
    private var completion: ((Result<URL, Error>) -> Void)?
    private static var current: FilePicker?

    static func present(completion: @escaping (Result<URL, Error>) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .data], asCopy: true)
        picker.allowsMultipleSelection = false
        let delegate = FilePicker()
        delegate.completion = completion
        picker.delegate = delegate
        current = delegate // keep alive while presented

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } 
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { completion?(.success(url)) }
        Self.current = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Self.current = nil
    }
}
