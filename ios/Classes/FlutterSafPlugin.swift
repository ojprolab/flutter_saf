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

    // MARK: - Pick Directory

    private func pickDirectory(result: @escaping FlutterResult) {
        guard let viewController = viewController else {
            result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "No view controller available", details: nil))
            return
        }

        if pendingResult != nil {
            result(FlutterError(code: "ALREADY_ACTIVE", message: "Another pick operation is in progress", details: nil))
            return
        }

        pendingResult = result

        let documentPicker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        } else {
            documentPicker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
        }

        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = false
        documentPicker.shouldShowFileExtensions = true

        viewController.present(documentPicker, animated: true)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            pendingResult?(FlutterError(code: "INVALID_URL", message: "No URL selected", details: nil))
            pendingResult = nil
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            pendingResult?(FlutterError(code: "ACCESS_DENIED", message: "Cannot access directory", details: nil))
            pendingResult = nil
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let bookmarkData = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            let bookmarkKey = url.path
            saveBookmark(bookmarkData, for: bookmarkKey)

            let directoryInfo: [String: Any] = [
                "uri": url.absoluteString,
                "name": url.lastPathComponent,
                "path": url.path,
                "bookmarkKey": bookmarkKey
            ]

            pendingResult?(directoryInfo)
        } catch {
            pendingResult?(FlutterError(code: "BOOKMARK_ERROR", message: "Failed to create bookmark: \(error.localizedDescription)", details: nil))
        }

        pendingResult = nil
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingResult?(FlutterError(code: "CANCELLED", message: "User cancelled directory selection", details: nil))
        pendingResult = nil
    }

    // MARK: - Scan Directory

    private func scanDirectory(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let directoryUri = args["uri"] as? String,
              let url = parseURL(from: directoryUri) else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Valid directoryUri is required", details: nil))
            return
        }

        let extensions = args["extensions"] as? [String] ?? []
        let recursive = args["recursive"] as? Bool ?? true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            guard let parentURL = self.resolveBookmark(for: url) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NO_BOOKMARK", message: "No bookmark found. Please pick the directory first.", details: nil))
                }
                return
            }

            guard parentURL.startAccessingSecurityScopedResource() else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "ACCESS_DENIED", message: "Cannot access directory", details: nil))
                }
                return
            }
            defer { parentURL.stopAccessingSecurityScopedResource() }

            do {
                let files = try self.scanFiles(at: url, extensions: extensions, recursive: recursive)
                DispatchQueue.main.async {
                    result(files)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "SCAN_ERROR", message: "Error scanning directory: \(error.localizedDescription)", details: nil))
                }
            }
        }
    }

    private func scanFiles(at url: URL, extensions: [String], recursive: Bool) throws -> [[String: Any]] {
        let fileManager = FileManager.default
        var result: [[String: Any]] = []

        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        for fileURL in contents {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])

            if resourceValues.isDirectory == true {
                if recursive {
                    let subFiles = try scanFiles(at: fileURL, extensions: extensions, recursive: recursive)
                    result.append(contentsOf: subFiles)
                }
            } else if shouldIncludeFile(fileURL, extensions: extensions) {
                let fileInfo: [String: Any] = [
                    "uri": fileURL.absoluteString,
                    "name": fileURL.lastPathComponent,
                    "path": fileURL.path,
                    "size": resourceValues.fileSize ?? 0,
                    "mimeType": getMimeType(for: fileURL) as Any,
                    "lastModified": Int64((resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
                ]
                result.append(fileInfo)
            }
        }

        return result
    }

    private func shouldIncludeFile(_ url: URL, extensions: [String]) -> Bool {
        guard !extensions.isEmpty else { return true }
        let fileExtension = url.pathExtension.lowercased()
        return extensions.contains { $0.lowercased() == fileExtension }
    }

    // MARK: - Read File

    private func readFileBytes(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let fileUri = args["uri"] as? String,
              let fileURL = parseURL(from: fileUri) else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Valid fileUri is required", details: nil))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            guard let parentURL = self.resolveBookmark(for: fileURL) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NO_PARENT", message: "No parent directory bookmark found. Please pick the directory first.", details: nil))
                }
                return
            }

            guard parentURL.startAccessingSecurityScopedResource() else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "ACCESS_DENIED", message: "Cannot access file", details: nil))
                }
                return
            }
            defer { parentURL.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: fileURL)
                let flutterData = FlutterStandardTypedData(bytes: data)
                DispatchQueue.main.async {
                    result(flutterData)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "READ_ERROR", message: "Error reading file: \(error.localizedDescription)", details: nil))
                }
            }
        }
    }

    // MARK: - Check Access

    private func checkAccess(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let uri = args["uri"] as? String,
              let url = parseURL(from: uri) else {
            result(false)
            return
        }

        // Try to resolve bookmark for security-scoped resources
        if let parentURL = resolveBookmark(for: url) {
            guard parentURL.startAccessingSecurityScopedResource() else {
                result(false)
                return
            }
            defer { parentURL.stopAccessingSecurityScopedResource() }
        }

        // Check if file/directory exists
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        // If checking for directory specifically (original behavior)
        if let _ = args["checkDirectory"] as? Bool {
            result(exists && isDirectory.boolValue)
        } else {
            // Check for any file or directory
            result(exists)
        }
    }

    // MARK: - Bookmark Management

    private func saveBookmark(_ bookmarkData: Data, for key: String) {
        var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkKey) as? [String: Data] ?? [:]
        bookmarks[key] = bookmarkData
        UserDefaults.standard.set(bookmarks, forKey: bookmarkKey)
    }

    private func resolveBookmark(for fileURL: URL) -> URL? {
        let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkKey) as? [String: Data] ?? [:]
        let filePath = fileURL.path

        // Find the longest matching bookmark path (most specific parent)
        var bestMatch: (url: URL, pathLength: Int)?

        for (savedPath, bookmarkData) in bookmarks {
            guard filePath.hasPrefix(savedPath) || filePath == savedPath else { continue }

            var isStale = false
            guard let directoryURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }

            // Refresh stale bookmark
            if isStale {
                refreshBookmark(for: savedPath, url: directoryURL)
            }

            let pathLength = savedPath.count
            if bestMatch == nil || pathLength > bestMatch!.pathLength {
                bestMatch = (directoryURL, pathLength)
            }
        }

        return bestMatch?.url
    }

    private func refreshBookmark(for key: String, url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        if let newBookmarkData = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            saveBookmark(newBookmarkData, for: key)
        }
    }

    // MARK: - Utilities

    private func parseURL(from uri: String) -> URL? {
        if uri.hasPrefix("file://") {
            return URL(string: uri)
        } else {
            return URL(fileURLWithPath: uri)
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
}
