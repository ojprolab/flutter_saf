import Flutter
import UIKit
import UniformTypeIdentifiers

public class FlutterSafPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private var pendingResult: FlutterResult?
  private var viewController: UIViewController?

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

    let shouldStopAccessing = url.startAccessingSecurityScopedResource()
    defer {
      if shouldStopAccessing {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let DirectoryInfo: [String: Any] = [
      "uri": url.absoluteString,
      "name": url.lastPathComponent,
      "path": url.path
    ]

    pendingResult?(DirectoryInfo)
    pendingResult = nil
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingResult?(FlutterError(code: "CANCELLED", message: "User cancelled folder selection", details: nil))
    pendingResult = nil
  }
}
