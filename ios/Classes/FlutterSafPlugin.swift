import Flutter
import UIKit
import UniformTypeIdentifiers

public class FlutterSafPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
    private var pendingResult: FlutterResult?
    private var viewController: UIViewController?
    private let bookmarkKey = "com.ojprolab.flutter_saf.bookmarks"

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "flutter_saf", binaryMessenger: registrar.messenger())
        let instance = FlutterSafPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)

        if let viewController = UIApplication.shared.delegate?.window??.rootViewController {
            instance.viewController = viewController
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pickDirectory":
            pickDirectory(result: result)
        case "scanDirectory":
            scanDirectory(call: call, result: result)
        case "readFileBytes":
            readFileBytes(call: call, result: result)
        case "checkAccess":
            checkAccess(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func extractStableKey(from url: URL) -> (key: String, storageType: String) {
        let fullPath = url.standardizedFileURL.path

        if let range = fullPath.range(of: "/com~apple~CloudDocs/") {
            let key = String(fullPath[range.upperBound...])
            return (key.isEmpty ? fullPath : key, "icloud")
        }

        if let range = fullPath.range(of: "/File Provider Storage/") {
            let key = String(fullPath[range.upperBound...])
            return (key.isEmpty ? fullPath : key, "local")
        }

        if let range = fullPath.range(of: "/Documents/") {
            let key = String(fullPath[range.upperBound...])
            return (key.isEmpty ? fullPath : key, "documents")
        }

        let components = url.pathComponents
        let fallbackKey = components.suffix(min(2, components.count)).joined(separator: "/")
        return (fallbackKey, "unknown")
    }

    private func pickDirectory(result: @escaping FlutterResult) {
        guard let viewController = viewController else {
            result(
                FlutterError(
                    code: "NO_VIEW_CONTROLLER", message: "No view controller available",
                    details: nil))
            return
        }

        if pendingResult != nil {
            result(
                FlutterError(
                    code: "ALREADY_ACTIVE", message: "Another pick operation is in progress",
                    details: nil))
            return
        }

        pendingResult = result

        let documentPicker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        } else {
            documentPicker = UIDocumentPickerViewController(
                documentTypes: ["public.folder"], in: .open)
        }

        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = false
        documentPicker.shouldShowFileExtensions = true

        viewController.present(documentPicker, animated: true)
    }

    public func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else {
            pendingResult?(
                FlutterError(code: "INVALID_URL", message: "No URL selected", details: nil))
            pendingResult = nil
            return
        }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let bookmarkData = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            let (stableKey, storageType) = extractStableKey(from: url)
            let finalKey = "\(storageType):\(stableKey)"
            saveBookmark(bookmarkData, for: finalKey)

            let directoryInfo: [String: Any] = [
                "uri": url.absoluteString,
                "name": url.lastPathComponent,
                "path": url.standardizedFileURL.path,
                "bookmarkKey": finalKey,
                "storageType": storageType,
            ]

            pendingResult?(directoryInfo)
        } catch {
            pendingResult?(
                FlutterError(
                    code: "BOOKMARK_ERROR",
                    message: "Failed to create bookmark: \(error.localizedDescription)",
                    details: nil))
        }

        pendingResult = nil
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingResult?(
            FlutterError(
                code: "CANCELLED", message: "User cancelled directory selection", details: nil))
        pendingResult = nil
    }

    private func scanDirectory(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let directoryUri = args["uri"] as? String
        else {
            result(
                FlutterError(
                    code: "INVALID_ARGUMENTS", message: "directoryUri is required", details: nil))
            return
        }

        let extensions = args["extensions"] as? [String] ?? []
        let recursive = args["recursive"] as? Bool ?? true

        guard let url = URL(string: directoryUri) else {
            result(
                FlutterError(
                    code: "INVALID_URI", message: "Invalid directory URI", details: nil))
            return
        }

        guard let parentURL = findParentDirectoryURL(for: url) else {
            result(
                FlutterError(
                    code: "NO_BOOKMARK",
                    message: "No bookmark found for directory. Please pick the directory first.",
                    details: nil))
            return
        }

        let didStartAccessing = parentURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                parentURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            var files: [[String: Any]] = []
            try scanFiles(at: url, extensions: extensions, recursive: recursive, result: &files)
            result(files)
        } catch {
            result(
                FlutterError(
                    code: "SCAN_ERROR",
                    message: "Error scanning directory: \(error.localizedDescription)", details: nil
                ))
        }
    }

    private func saveBookmark(_ bookmarkData: Data, for key: String) {
        var bookmarks =
            UserDefaults.standard.dictionary(forKey: bookmarkKey) as? [String: Data] ?? [:]
        bookmarks[key] = bookmarkData
        UserDefaults.standard.set(bookmarks, forKey: bookmarkKey)
    }

    private func findParentDirectoryURL(for fileURL: URL) -> URL? {
        let bookmarks =
            UserDefaults.standard.dictionary(forKey: bookmarkKey) as? [String: Data] ?? [:]
        let (fileStableKey, storageType) = extractStableKey(from: fileURL)
        let fileFinalKey = "\(storageType):\(fileStableKey)"

        var bestMatch: (url: URL, keyLength: Int)?

        for (savedKey, bookmarkData) in bookmarks {
            var isStale = false
            guard
                let directoryURL = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withoutUI,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            else { continue }

            if fileFinalKey.hasPrefix(savedKey + "/") || fileFinalKey == savedKey {
                let keyLength = savedKey.count
                if bestMatch == nil || keyLength > bestMatch!.keyLength {
                    bestMatch = (directoryURL, keyLength)
                }
            }

            if isStale {
                if directoryURL.startAccessingSecurityScopedResource() {
                    defer { directoryURL.stopAccessingSecurityScopedResource() }

                    if let newBookmarkData = try? directoryURL.bookmarkData(
                        options: .minimalBookmark,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        saveBookmark(newBookmarkData, for: savedKey)
                    }
                }
            }
        }

        return bestMatch?.url
    }

    private func readFileBytes(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let fileUri = args["uri"] as? String
        else {
            result(
                FlutterError(
                    code: "INVALID_ARGUMENTS", message: "fileUri is required", details: nil))
            return
        }

        let fileURL: URL
        if fileUri.hasPrefix("file://") {
            guard let url = URL(string: fileUri) else {
                result(
                    FlutterError(
                        code: "INVALID_URI", message: "Invalid file URI", details: nil))
                return
            }
            fileURL = url
        } else {
            fileURL = URL(fileURLWithPath: fileUri)
        }

        guard let parentURL = findParentDirectoryURL(for: fileURL) else {
            result(
                FlutterError(
                    code: "NO_PARENT",
                    message: "No parent directory bookmark found. Please pick the directory first.",
                    details: nil))
            return
        }

        let didStartAccessing = parentURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                parentURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let flutterData = FlutterStandardTypedData(bytes: data)
            result(flutterData)
        } catch {
            result(
                FlutterError(
                    code: "READ_ERROR",
                    message: "Error reading file: \(error.localizedDescription)", details: nil))
        }
    }

    private func scanFiles(
        at url: URL, extensions: [String], recursive: Bool, result: inout [[String: Any]]
    ) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        )

        for fileURL in contents {
            let resourceValues = try fileURL.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ])

            if resourceValues.isDirectory == true {
                if recursive {
                    try scanFiles(
                        at: fileURL, extensions: extensions, recursive: recursive, result: &result)
                }
            } else {
                let shouldInclude: Bool
                if extensions.isEmpty {
                    shouldInclude = true
                } else {
                    let fileExtension = fileURL.pathExtension.lowercased()
                    shouldInclude = extensions.contains { $0.lowercased() == fileExtension }
                }

                if shouldInclude {
                    let fileInfo: [String: Any] = [
                        "uri": fileURL.absoluteString,
                        "name": fileURL.lastPathComponent,
                        "path": fileURL.path,
                        "size": resourceValues.fileSize ?? 0,
                        "mimeType": getMimeType(for: fileURL) as Any,
                        "lastModified": Int64(
                            (resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0)
                                * 1000),
                    ]
                    result.append(fileInfo)
                }
            }
        }
    }

    private func getMimeType(for url: URL) -> String? {
        if #available(iOS 14.0, *) {
            if let utType = UTType(filenameExtension: url.pathExtension) {
                return utType.preferredMIMEType
            }
        }
        return nil
    }

    private func checkAccess(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let directoryUri = args["uri"] as? String
        else {
            result(false)
            return
        }

        let directoryURL: URL
        if directoryUri.hasPrefix("file://") {
            guard let url = URL(string: directoryUri) else {
                result(false)
                return
            }
            directoryURL = url
        } else {
            directoryURL = URL(fileURLWithPath: directoryUri)
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: directoryURL.path, isDirectory: &isDirectory)
        result(exists && isDirectory.boolValue)
    }
}
