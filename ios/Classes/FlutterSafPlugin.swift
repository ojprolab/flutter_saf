import Flutter
import UIKit
import UniformTypeIdentifiers

public class FlutterSafPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private var pendingResult: FlutterResult?
  private var viewController: UIViewController?
  private let bookmarkKey = "com.ojprolab.flutter_saf.bookmarks"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_saf", binaryMessenger: registrar.messenger())
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
    default:
      result(FlutterMethodNotImplemented)
    }
  }

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
      pendingResult?(FlutterError(code: "ACCESS_DENIED", message: "Failed to access security scoped resource", details: nil))
      pendingResult = nil
      return
    }

    defer {
      url.stopAccessingSecurityScopedResource()
    }

    do {
      let bookmarkData = try url.bookmarkData(
        options: .minimalBookmark,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )

      saveBookmark(bookmarkData, for: url.absoluteString)

      let directoryInfo: [String: Any] = [
        "uri": url.absoluteString,
        "name": url.lastPathComponent,
        "path": url.path
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

  private func scanDirectory(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let directoryUri = args["uri"] as? String else {
          result(FlutterError(code: "INVALID_ARGUMENTS", message: "directoryUri is required", details: nil))
      return
    }

    let extensions = args["extensions"] as? [String] ?? []
    let recursive = args["recursive"] as? Bool ?? true

    guard let url = resolveSecurityScopedURL(from: directoryUri) else {
      result(FlutterError(code: "INVALID_URI", message: "Cannot resolve URL or bookmark not found", details: nil))
      return
    }

    guard url.startAccessingSecurityScopedResource() else {
      result(FlutterError(code: "ACCESS_DENIED", message: "Failed to access security scoped resource", details: nil))
      return
    }

    defer {
      url.stopAccessingSecurityScopedResource()
    }

    do {
      var files: [[String: Any]] = []
      try scanFiles(at: url, extensions: extensions, recursive: recursive, result: &files)
      result(files)
    } catch {
      result(FlutterError(code: "SCAN_ERROR", message: "Error scanning directory: \(error.localizedDescription)", details: nil))
    }
  }

  private func saveBookmark(_ bookmarkData: Data, for uriString: String) {
    var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkKey) as? [String: Data] ?? [:]
    bookmarks[uriString] = bookmarkData
    UserDefaults.standard.set(bookmarks, forKey: bookmarkKey)
  }

  private func loadBookmark(for uriString: String) -> Data? {
    let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkKey) as? [String: Data]
    return bookmarks?[uriString]
  }

  private func resolveSecurityScopedURL(from uriString: String) -> URL? {
    guard let bookmarkData = loadBookmark(for: uriString) else {
      return nil
    }

    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: bookmarkData,
        options: .withoutUI,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )

      if isStale {
        if url.startAccessingSecurityScopedResource() {
          defer { url.stopAccessingSecurityScopedResource() }

          if let newBookmarkData = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            saveBookmark(newBookmarkData, for: uriString)
          }
        }
      }

      return url
    } catch {
      return nil
    }
  }

  private func scanFiles(at url: URL, extensions: [String], recursive: Bool, result: inout [[String: Any]]) throws {
    let fileManager = FileManager.default
    let contents = try fileManager.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )

    for fileURL in contents {
      let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])

      if resourceValues.isDirectory == true {
        if recursive {
          try scanFiles(at: fileURL, extensions: extensions, recursive: recursive, result: &result)
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
            "lastModified": Int64((resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
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
}
