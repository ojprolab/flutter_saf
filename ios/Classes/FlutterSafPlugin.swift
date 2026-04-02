import Flutter
import UIKit
import UniformTypeIdentifiers

public class FlutterSafPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {

    private let methodChannelName   = "flutter_saf"
    private let bookmarkDefaultsKey = "com.ojprolab.flutter_saf.bookmarks"

    private var methodChannel: FlutterMethodChannel?
    private var pendingPickResult: FlutterResult?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FlutterSafPlugin()
        let channel  = FlutterMethodChannel(
            name: instance.methodChannelName,
            binaryMessenger: registrar.messenger()
        )
        instance.methodChannel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pickDirectory":     pickDirectory(result: result)
        case "scanDirectory":     scanDirectory(call: call, result: result)
        case "readFileBytes":     readFileBytes(call: call, result: result)
        case "readBytesAt":       readBytesAt(call: call, result: result)
        case "copyFileToPath":    copyFileToPath(call: call, result: result)
        case "checkAccess":       checkAccess(call: call, result: result)
        case "deleteFile":        deleteFile(call: call, result: result)
        case "renameFile":        renameFile(call: call, result: result)
        case "exists":            exists(call: call, result: result)
        case "getFileMetadata":   getFileMetadata(call: call, result: result)
        case "releasePermission": releasePermission(call: call, result: result)
        default:                  result(FlutterMethodNotImplemented)
        }
    }

    // ── pickDirectory ─────────────────────────────────────────────────────────
    // Result:  { uri, name, path, bookmarkKey, storageType }
    // Errors:  NO_VIEW_CONTROLLER | ALREADY_ACTIVE | ACCESS_DENIED |
    //          BOOKMARK_ERROR | INVALID_URL | CANCELLED

    private func pickDirectory(result: @escaping FlutterResult) {
        guard let vc = presentingViewController() else {
            return result(err("NO_VIEW_CONTROLLER", "No root view controller available"))
        }
        guard pendingPickResult == nil else {
            return result(err("ALREADY_ACTIVE", "Another pick operation is already in progress"))
        }
        pendingPickResult = result

        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
        }
        picker.delegate = self
        picker.allowsMultipleSelection = false
        vc.present(picker, animated: true)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController,
                                didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            pendingPickResult?(err("INVALID_URL", "No URL returned from picker"))
            pendingPickResult = nil
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            pendingPickResult?(err("ACCESS_DENIED", "Cannot access the selected directory"))
            pendingPickResult = nil
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            saveBookmark(bookmark, forKey: url.path)
            pendingPickResult?([
                "uri":         url.absoluteString,
                "name":        url.lastPathComponent,
                "path":        url.path,
                "bookmarkKey": url.path,
                "storageType": "ios",
            ] as [String: Any])
        } catch {
            pendingPickResult?(err("BOOKMARK_ERROR", error.localizedDescription))
        }
        pendingPickResult = nil
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingPickResult?(err("CANCELLED", "User cancelled the folder picker"))
        pendingPickResult = nil
    }

    // ── scanDirectory ─────────────────────────────────────────────────────────
    // Arguments: uri*, extensions, recursive, taskId, includeHidden,
    //            minSize, maxSize, sortBy, sortDescending, limit
    // Progress:  onProgress { taskId, progress 0–1, status }
    // Result:    [{ uri, name, path, size, mimeType, lastModified }]
    // Errors:    INVALID_ARGUMENTS | NO_BOOKMARK | ACCESS_DENIED | SCAN_ERROR

    private func scanDirectory(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args         = call.arguments as? [String: Any],
              let directoryUri = args["uri"] as? String,
              let rootURL      = parseURL(from: directoryUri) else {
            return result(err("INVALID_ARGUMENTS", "Valid uri is required"))
        }

        let extensions     = args["extensions"]     as? [String] ?? []
        let recursive      = args["recursive"]      as? Bool ?? true
        let taskId         = args["taskId"]         as? String ?? autoTaskId("scan")
        let includeHidden  = args["includeHidden"]  as? Bool ?? false
        let minSize        = args["minSize"]        as? Int
        let maxSize        = args["maxSize"]        as? Int
        let sortBy         = args["sortBy"]         as? String
        let sortDescending = args["sortDescending"] as? Bool ?? false
        let limit          = args["limit"]          as? Int

        runInBackground { [weak self] in
            guard let self = self else { return }

            let needsScoped = !self.isInAppContainer(url: rootURL)
            var scopedURL: URL?
            if needsScoped {
                guard let resolved = self.resolveBookmark(for: rootURL) else {
                    return self.postToMain { result(self.err("NO_BOOKMARK", "No bookmark found for: \(directoryUri)")) }
                }
                guard resolved.startAccessingSecurityScopedResource() else {
                    return self.postToMain { result(self.err("ACCESS_DENIED", "Cannot access: \(directoryUri)")) }
                }
                scopedURL = resolved
            } else {
                if let resolved = self.resolveBookmark(for: rootURL) {
                    guard resolved.startAccessingSecurityScopedResource() else {
                        return self.postToMain { result(self.err("ACCESS_DENIED", "Cannot access")) }
                    }
                    scopedURL = resolved
                } else {
                    print("DEBUG: No bookmark found for app container path, proceeding without scoped access")
                }
            }
            defer { scopedURL?.stopAccessingSecurityScopedResource() }

            do {
                self.sendProgress(taskId: taskId, progress: 0.0, status: "scanning")
                var files = try self.collectFilesEnumerator(
                    at: rootURL, extensions: extensions, recursive: recursive,
                    includeHidden: includeHidden, minSize: minSize, maxSize: maxSize,
                    taskId: taskId, limit: limit
                )

                switch sortBy {
                case "name":
                    files.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
                    if sortDescending { files.reverse() }
                case "size":
                    files.sort { ($0["size"] as? Int ?? 0) < ($1["size"] as? Int ?? 0) }
                    if sortDescending { files.reverse() }
                case "lastModified":
                    files.sort { ($0["lastModified"] as? Int64 ?? 0) < ($1["lastModified"] as? Int64 ?? 0) }
                    if sortDescending { files.reverse() }
                default: break
                }

                self.sendProgress(taskId: taskId, progress: 1.0, status: "done")
                self.postToMain { result(files) }
            } catch {
                self.postToMain { result(self.err("SCAN_ERROR", error.localizedDescription)) }
            }
        }
    }

    private func collectFilesEnumerator(
        at url: URL, extensions: [String], recursive: Bool,
        includeHidden: Bool, minSize: Int?, maxSize: Int?,
        taskId: String, limit: Int?
    ) throws -> [[String: Any]] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: includeHidden ? [] : [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadNoPermission)
        }

        var results: [[String: Any]] = []

        for case let fileURL as URL in enumerator {
            if let lim = limit, results.count >= lim { break }
            guard let res = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }

            if res.isDirectory == true {
                if !recursive { enumerator.skipDescendants() }
                continue
            }

            if !matchesExtension(fileURL, extensions: extensions) { continue }

            let size = res.fileSize ?? 0
            if let min = minSize, size < min { continue }
            if let max = maxSize, size > max { continue }

            let modMs = Int64((res.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            results.append([
                "uri":          fileURL.absoluteString,
                "name":         fileURL.lastPathComponent,
                "path":         fileURL.path,
                "size":         size,
                "mimeType":     mimeType(for: fileURL) as Any,
                "lastModified": modMs,
            ])

            sendProgress(taskId: taskId, progress: min(Double(results.count) / 1000.0, 0.9), status: "scanning")
        }

        return results
    }

    // ── readFileBytes ─────────────────────────────────────────────────────────
    // Arguments: uri*, taskId, maxBytes
    // Progress:  onProgress { taskId, progress, status "reading"|"done" }
    // Result:    FlutterStandardTypedData (Uint8List)
    // Errors:    INVALID_ARGUMENTS | NO_BOOKMARK | ACCESS_DENIED |
    //            READ_ERROR | FILE_TOO_LARGE

    private func readFileBytes(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args    = call.arguments as? [String: Any],
              let fileUri = args["uri"] as? String,
              let fileURL = parseURL(from: fileUri) else {
            return result(err("INVALID_ARGUMENTS", "Valid uri is required"))
        }

        let taskId   = args["taskId"]   as? String ?? autoTaskId("read")
        let maxBytes = args["maxBytes"] as? Int

        runInBackground { [weak self] in
            guard let self = self else { return }
            self.withScopedAccess(to: fileURL, result: result) { resolvedURL in
                let ioURL = resolvedURL ?? fileURL

                if let max = maxBytes,
                   let size = (try? FileManager.default.attributesOfItem(atPath: ioURL.path)[.size] as? Int),
                   size > max {
                    return self.postToMain {
                        result(self.err("FILE_TOO_LARGE", "File is \(size) bytes, maxBytes is \(max)"))
                    }
                }

                self.doReadFileBytes(fileURL: ioURL, taskId: taskId, result: result)
            }
        }
    }

    // ── readBytesAt ───────────────────────────────────────────────────────────────
    // Arguments: uri*, position (Int), size (Int)
    // Result:    FlutterStandardTypedData (Uint8List)
    // Errors:    INVALID_ARGUMENTS | READ_ERROR
    //
    // NOTE: On iOS openFile() works directly with the file URL so this is rarely
    // needed. Included for completeness.

    private func readBytesAt(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args     = call.arguments as? [String: Any],
              let fileUri  = args["uri"]      as? String,
              let fileURL  = parseURL(from: fileUri),
              let position = (args["position"] as? NSNumber)?.uint64Value,
              let size     = (args["size"]     as? NSNumber)?.intValue else {
            return result(err("INVALID_ARGUMENTS", "uri, position and size are required"))
        }

        runInBackground { [weak self] in
            guard let self = self else { return }
            do {
                // FileHandle gives true random-access (no full file in memory)
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { handle.closeFile() }

                handle.seek(toFileOffset: position)
                let data = handle.readData(ofLength: size)

                self.postToMain {
                    result(FlutterStandardTypedData(bytes: data))
                }
            } catch {
                self.postToMain {
                    result(self.err("READ_ERROR", error.localizedDescription))
                }
            }
        }
    }

    private func doReadFileBytes(fileURL: URL, taskId: String, result: @escaping FlutterResult) {
        guard let stream = InputStream(url: fileURL) else {
            return postToMain { result(self.err("READ_ERROR", "Cannot open InputStream for: \(fileURL.path)")) }
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        stream.open()
        defer { stream.close() }

        sendProgress(taskId: taskId, progress: 0.0, status: "reading")

        var data    = Data(capacity: max(fileSize, 0))
        let bufSize = 32 * 1024
        var buf     = [UInt8](repeating: 0, count: bufSize)

        do {
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: bufSize)
                guard n >= 0 else { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
                data.append(contentsOf: buf[0..<n])
                if fileSize > 0 {
                    sendProgress(taskId: taskId, progress: Double(data.count) / Double(fileSize), status: "reading")
                }
            }
            sendProgress(taskId: taskId, progress: 1.0, status: "done")
            postToMain { result(FlutterStandardTypedData(bytes: data)) }
        } catch {
            postToMain { result(self.err("READ_ERROR", error.localizedDescription)) }
        }
    }

    // ── copyFileToPath ────────────────────────────────────────────────────────
    // Arguments: uri*, destPath*, taskId, overwrite, bufferSize
    // Progress:  onProgress { taskId, progress, status "copying"|"done" }
    // Result:    destPath string
    // Errors:    INVALID_ARGUMENTS | NO_BOOKMARK | ACCESS_DENIED | STREAM_ERROR |
    //            COPY_ERROR | ALREADY_EXISTS | WRITE_ERROR

    private func copyFileToPath(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args     = call.arguments as? [String: Any],
              let fileUri  = args["uri"] as? String,
              let destPath = args["destPath"] as? String,
              let fileURL  = parseURL(from: fileUri) else {
            return result(err("INVALID_ARGUMENTS", "uri and destPath are required"))
        }

        let taskId     = args["taskId"]     as? String ?? autoTaskId("copy")
        let overwrite  = args["overwrite"]  as? Bool ?? true
        let bufferSize = (args["bufferSize"] as? Int ?? 32768).clamped(to: 1024...Int.max)
        let destURL    = URL(fileURLWithPath: destPath)

        runInBackground { [weak self] in
            guard let self = self else { return }
            self.withScopedAccess(to: fileURL, result: result) { resolvedURL in
                self.doCopyFile(from: resolvedURL ?? fileURL, to: destURL,
                                taskId: taskId, overwrite: overwrite,
                                bufferSize: bufferSize, result: result)
            }
        }
    }

    private func doCopyFile(from sourceURL: URL, to destURL: URL,
                             taskId: String, overwrite: Bool,
                             bufferSize: Int, result: @escaping FlutterResult) {
        do {
            if !overwrite && FileManager.default.fileExists(atPath: destURL.path) {
                return postToMain { result(self.err("ALREADY_EXISTS", "Destination already exists: \(destURL.path)")) }
            }

            try FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }

            guard let input  = InputStream(url: sourceURL),
                  let output = OutputStream(url: destURL, append: false) else {
                return postToMain { result(self.err("STREAM_ERROR", "Cannot open streams")) }
            }

            input.open(); output.open()
            defer { input.close(); output.close() }

            let fileSize    = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int) ?? 0
            var totalCopied = 0
            var buf         = [UInt8](repeating: 0, count: bufferSize)

            sendProgress(taskId: taskId, progress: 0.0, status: "copying")

            while input.hasBytesAvailable {
                let bytesRead = input.read(&buf, maxLength: bufferSize)
                guard bytesRead >= 0 else { throw input.streamError ?? CocoaError(.fileReadUnknown) }
                if bytesRead == 0 { break }

                let written = output.write(buf, maxLength: bytesRead)
                guard written >= 0 else { throw output.streamError ?? CocoaError(.fileWriteOutOfSpace) }

                totalCopied += bytesRead
                if fileSize > 0 {
                    sendProgress(taskId: taskId, progress: Double(totalCopied) / Double(fileSize), status: "copying")
                }
            }

            sendProgress(taskId: taskId, progress: 1.0, status: "done")
            postToMain { result(destURL.path) }
        } catch {
            postToMain { result(self.err("COPY_ERROR", error.localizedDescription)) }
        }
    }

    // ── checkAccess ───────────────────────────────────────────────────────────
    // Arguments: uri*
    // Result:    Boolean

    private func checkAccess(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let uri  = args["uri"] as? String,
              let url  = parseURL(from: uri) else {
            return result(false)
        }

        if isInAppContainer(url: url) {
            return result(FileManager.default.fileExists(atPath: url.path))
        }

        if let scopedURL = resolveBookmark(for: url) {
            guard scopedURL.startAccessingSecurityScopedResource() else { return result(false) }
            defer { scopedURL.stopAccessingSecurityScopedResource() }
        }
        result(FileManager.default.fileExists(atPath: url.path))
    }

    // ── deleteFile ────────────────────────────────────────────────────────────
    // Arguments: uri*
    // Result:    Boolean
    // Errors:    INVALID_ARGUMENTS | NO_BOOKMARK | ACCESS_DENIED | DELETE_ERROR

    private func deleteFile(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args    = call.arguments as? [String: Any],
              let fileUri = args["uri"] as? String,
              let fileURL = parseURL(from: fileUri) else {
            return result(err("INVALID_ARGUMENTS", "Valid uri is required"))
        }

        runInBackground { [weak self] in
            guard let self = self else { return }
            self.withScopedAccess(to: fileURL, result: result) { resolvedURL in
                do {
                    try FileManager.default.removeItem(at: resolvedURL ?? fileURL)
                    self.postToMain { result(true) }
                } catch {
                    self.postToMain { result(self.err("DELETE_ERROR", error.localizedDescription)) }
                }
            }
        }
    }

    // ── renameFile ────────────────────────────────────────────────────────────
    // Arguments: uri*, newName | destPath
    // Result:    new path string
    // Errors:    INVALID_ARGUMENTS | NO_BOOKMARK | ACCESS_DENIED | RENAME_ERROR

    private func renameFile(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args    = call.arguments as? [String: Any],
              let fileUri = args["uri"] as? String,
              let fileURL = parseURL(from: fileUri) else {
            return result(err("INVALID_ARGUMENTS", "Valid uri is required"))
        }

        let destURL: URL
        if let dp = args["destPath"] as? String {
            destURL = URL(fileURLWithPath: dp)
        } else if let newName = args["newName"] as? String {
            destURL = fileURL.deletingLastPathComponent().appendingPathComponent(newName)
        } else {
            return result(err("INVALID_ARGUMENTS", "Either newName or destPath is required"))
        }

        runInBackground { [weak self] in
            guard let self = self else { return }
            self.withScopedAccess(to: fileURL, result: result) { resolvedURL in
                do {
                    try FileManager.default.moveItem(at: resolvedURL ?? fileURL, to: destURL)
                    self.postToMain { result(destURL.path) }
                } catch {
                    self.postToMain { result(self.err("RENAME_ERROR", error.localizedDescription)) }
                }
            }
        }
    }

    // ── exists ────────────────────────────────────────────────────────────────
    // Arguments: uri*
    // Result:    Boolean

    private func exists(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let uri  = args["uri"] as? String,
              let url  = parseURL(from: uri) else {
            return result(false)
        }
        result(FileManager.default.fileExists(atPath: url.path))
    }

    // ── getFileMetadata ───────────────────────────────────────────────────────
    // Arguments: uri*
    // Result:    { uri, name, path, size, mimeType, lastModified, isDirectory, isWritable }
    // Errors:    INVALID_ARGUMENTS | NO_BOOKMARK | ACCESS_DENIED | METADATA_ERROR

    private func getFileMetadata(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args    = call.arguments as? [String: Any],
              let fileUri = args["uri"] as? String,
              let fileURL = parseURL(from: fileUri) else {
            return result(err("INVALID_ARGUMENTS", "Valid uri is required"))
        }

        runInBackground { [weak self] in
            guard let self = self else { return }
            self.withScopedAccess(to: fileURL, result: result) { resolvedURL in
                let ioURL = resolvedURL ?? fileURL
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: ioURL.path)
                    let modMs = Int64(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
                    let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
                    self.postToMain {
                        result([
                            "uri":          ioURL.absoluteString,
                            "name":         ioURL.lastPathComponent,
                            "path":         ioURL.path,
                            "size":         attrs[.size] as? Int ?? 0,
                            "mimeType":     self.mimeType(for: ioURL) as Any,
                            "lastModified": modMs,
                            "isDirectory":  isDir,
                            "isWritable":   FileManager.default.isWritableFile(atPath: ioURL.path),
                        ] as [String: Any])
                    }
                } catch {
                    self.postToMain { result(self.err("METADATA_ERROR", error.localizedDescription)) }
                }
            }
        }
    }

    // ── releasePermission ─────────────────────────────────────────────────────
    // Arguments: uri*
    // Result:    Boolean
    // Errors:    INVALID_ARGUMENTS

    private func releasePermission(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let uri  = args["uri"] as? String else {
            return result(err("INVALID_ARGUMENTS", "uri is required"))
        }
        removeBookmark(forKey: uri)
        result(true)
    }

    // ── Scoped access helper ──────────────────────────────────────────────────

    private func withScopedAccess(
        to fileURL: URL,
        result: @escaping FlutterResult,
        body: @escaping (URL?) -> Void
    ) {
        if isInAppContainer(url: fileURL) { body(nil); return }

        guard let scopedURL = resolveBookmark(for: fileURL) else {
            postToMain { result(self.err("NO_BOOKMARK", "No bookmark for: \(fileURL.path)")) }
            return
        }
        guard scopedURL.startAccessingSecurityScopedResource() else {
            postToMain { result(self.err("ACCESS_DENIED", "Cannot access: \(fileURL.path)")) }
            return
        }
        defer { scopedURL.stopAccessingSecurityScopedResource() }

        // If bookmark resolved to a directory, reconstruct the full file URL
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: scopedURL.path, isDirectory: &isDir)
        let resolvedURL = isDir.boolValue
            ? scopedURL.appendingPathComponent(fileURL.lastPathComponent)
            : scopedURL

        body(resolvedURL)
    }

    // ── Bookmarks ─────────────────────────────────────────────────────────────

    private func saveBookmark(_ data: Data, forKey key: String) {
        var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey) as? [String: Data] ?? [:]
        bookmarks[key] = data
        UserDefaults.standard.set(bookmarks, forKey: bookmarkDefaultsKey)
    }

    private func removeBookmark(forKey key: String) {
        var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: key)
        UserDefaults.standard.set(bookmarks, forKey: bookmarkDefaultsKey)
    }

    private func resolveBookmark(for fileURL: URL) -> URL? {
        let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey) as? [String: Data] ?? [:]
        let filePath  = fileURL.path
        var bestMatch: (url: URL, keyLength: Int)?

        for (savedPath, bookmarkData) in bookmarks {
            guard filePath.hasPrefix(savedPath) || filePath == savedPath else { continue }
            var isStale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI, relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            if isStale { refreshBookmark(forKey: savedPath, url: resolved) }
            if bestMatch == nil || savedPath.count > bestMatch!.keyLength {
                bestMatch = (resolved, savedPath.count)
            }
        }
        return bestMatch?.url
    }

    private func refreshBookmark(forKey key: String, url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let data = try? url.bookmarkData(options: .minimalBookmark,
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil) {
            saveBookmark(data, forKey: key)
        }
    }

    // ── Utilities ─────────────────────────────────────────────────────────────

    private func runInBackground(_ block: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: block)
    }

    private func postToMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    // Combined channel: progress is pushed via invokeMethod("onProgress", …)
    // on the same MethodChannel. No separate EventChannel needed.
    private func sendProgress(taskId: String, progress: Double, status: String) {
        postToMain { [weak self] in
            self?.methodChannel?.invokeMethod("onProgress", arguments: [
                "taskId":   taskId,
                "progress": progress,
                "status":   status,
            ])
        }
    }

    private func matchesExtension(_ url: URL, extensions: [String]) -> Bool {
        guard !extensions.isEmpty else { return true }
        return extensions.contains { $0.lowercased() == url.pathExtension.lowercased() }
    }

    private func isInAppContainer(url: URL) -> Bool {
        let path = url.path
        let fm   = FileManager.default
        if let docs  = fm.urls(for: .documentDirectory, in: .userDomainMask).first, path.hasPrefix(docs.path)  { return true }
        if let cache = fm.urls(for: .cachesDirectory,   in: .userDomainMask).first, path.hasPrefix(cache.path) { return true }
        if path.contains("/AppGroup/") { return true }
        return false
    }

    private func parseURL(from uri: String) -> URL? {
        guard !uri.isEmpty else { return nil }
        return uri.hasPrefix("file://") ? URL(string: uri) : URL(fileURLWithPath: uri)
    }

    private func mimeType(for url: URL) -> String? {
        if #available(iOS 14.0, *) {
            return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        }
        return nil
    }

    private func presentingViewController() -> UIViewController? {
        UIApplication.shared.delegate?.window??.rootViewController
    }

    private func autoTaskId(_ prefix: String) -> String {
        "\(prefix)_\(Int(Date().timeIntervalSince1970 * 1000))"
    }

    private func err(_ code: String, _ message: String) -> FlutterError {
        FlutterError(code: code, message: message, details: nil)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
