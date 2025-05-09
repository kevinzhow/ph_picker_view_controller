import Flutter
import PhotosUI
import UIKit

class PluginArgumentError: NSObject, LocalizedError {
    var msg = ""
    init(_ msg: String) {
        self.msg = msg
    }
    
    override var description: String {
        get {
            return "PluginArgumentError: \(msg)"
        }
    }
    
    var errorDescription: String? {
        get {
            return self.description
        }
    }
}

struct ResultContext {
    let result: FlutterResult
    let fetchURL: Bool
}

public class SwiftPhPickerViewControllerPlugin: NSObject, FlutterPlugin {
    
    var completedTasksCounter = 0
    let taskCounterQueue = DispatchQueue(label: "ph_picker_view_controller_task_queue")
    var fileRepresentation: String?
    var resultContext: ResultContext?
    
    func currentViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.findKeyWindow()
        var topController = keyWindow?.rootViewController
        while topController?.presentedViewController != nil {
            topController = topController?.presentedViewController
        }
        return topController
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "ph_picker_view_controller", binaryMessenger: registrar.messenger())
        let instance = SwiftPhPickerViewControllerPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? Dictionary<String, Any> else {
            DispatchQueue.main.async {
                result(FlutterError(code: "InvalidArgsType", message: "Invalid args type", details: nil))
            }
            return
        }
        switch call.method {
        case "pick":
            do {
                // Arguments are enforced on dart side.
                let filterMap = args["filter"] as? [String: [String]]
                let fetchURL = args["fetchURL"] as? Bool
                let selectionLimit = args["selectionLimit"] as? Int
                let preferredAssetRepresentationMode = args["preferredAssetRepresentationMode"] as? String
                let selection = args["selection"] as? String
                fileRepresentation = args["fileRepresentation"] as? String
                resultContext = ResultContext(result: result, fetchURL: fetchURL == true)
                
                var configuration = PHPickerConfiguration(photoLibrary: .shared())
                if let filter = filterMap?.first {
                    configuration.filter = try filterFromMap(name: filter.key, filterNames: filter.value)
                }
                if let preferredAssetRepresentationMode = preferredAssetRepresentationMode {
                    configuration.preferredAssetRepresentationMode = try parseRepresentationMode(s: preferredAssetRepresentationMode)
                }
                if let selection = selection {
                    if #available(iOS 15.0, *) {
                        configuration.selection = try parseSelection(s: selection)
                    }
                }
                if let selectionLimit = selectionLimit {
                    configuration.selectionLimit = selectionLimit
                }
                let picker = PHPickerViewController(configuration: configuration)
                picker.delegate = self
                picker.presentationController?.delegate = self;
                
                currentViewController()?.present(picker, animated: true)
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "PluginError", message: error.localizedDescription, details: nil))
                }
            }
            
        case "fetch":
            // Arguments are enforced on dart side.
            guard let ids = args["ids"] as? [String] else {
                DispatchQueue.main.async {
                    result(false)
                }
                return
            }
            var outputList: [[String: Any?]] = ids.map { ["id": $0] }
            
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            completedTasksCounter = 0
            resultContext = ResultContext(result: result, fetchURL: true)
            
            guard assets.count > 0 else {
                if let resultContext = resultContext {
                    sendResults(resultContext: resultContext, results: [])
                }
                return
            }
            
            assets.enumerateObjects { [weak self] (obj: PHAsset, idx: Int, stopPtr: UnsafeMutablePointer<ObjCBool>) in
                guard let self else {
                    return
                }
                self.getUrl(asset: obj) { (url: URL?) in
                    outputList[idx]["url"] = url?.absoluteString
                    outputList[idx]["path"] = url?.path
                    outputList[idx]["error"] = url == nil ? "NotFound" : nil
                    
                    self.taskCounterQueue.async {
                        self.completedTasksCounter += 1
                        
                        if self.completedTasksCounter >= assets.count {
                            if let resultContext = self.resultContext {
                                self.sendResults(resultContext: resultContext, results: outputList)
                            }
                            return
                        }
                    }
                }
            }
          
        case "delete":
            // Arguments are enforced on dart side.
            guard let ids = args["ids"] as? [String] else {
                DispatchQueue.main.async {
                    result(false)
                }
                return
            }
            
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            } completionHandler: { success, error in
                if success {
                    DispatchQueue.main.async {
                        result(true)
                    }
                } else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "DeleteFailed", message: error?.localizedDescription, details: nil))
                    }
                }
            }
            
            
        default:
            DispatchQueue.main.async {
                result(FlutterMethodNotImplemented)
            }
        }
    }
    
    func filterFromMap(name: String, filterNames: [String]) throws -> PHPickerFilter {
        let filters = try filterNames.map({ filter in
            return try filterFromString(s: filter)
        })
        switch name {
        case "any":
            return PHPickerFilter.any(of: filters)
        case "not":
            if #available(iOS 15.0, *) {
                return PHPickerFilter.not(filters[0])
            } else {
                throw PluginArgumentError("not filter requires iOS 15.0")
            }
        case "all":
            if #available(iOS 15.0, *) {
                return PHPickerFilter.all(of: filters)
            } else {
                throw PluginArgumentError("all filter requires iOS 15.0")
            }
        default:
            throw PluginArgumentError("Unknown filter name \(name)")
        }
    }
    
    func getUrl(asset: PHAsset, completion: @escaping (URL?) -> Void) {
        switch asset.mediaType {
        case .image:
            let options = PHContentEditingInputRequestOptions()
            asset.requestContentEditingInput(with: options) { (contentEditingInput: PHContentEditingInput?, info: [AnyHashable : Any]) in
                completion(contentEditingInput!.fullSizeImageURL!)
            }
        case .video:
            let options = PHVideoRequestOptions()
            options.deliveryMode = .fastFormat
            options.version = .current
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { (asset: AVAsset?, audioMix: AVAudioMix?, info: [AnyHashable : Any]?) in
                if let urlAsset = asset {
                    completion((urlAsset as! AVURLAsset).url)
                } else {
                    completion(nil)
                }
            }
        default:
            break
        }
    }
}

extension SwiftPhPickerViewControllerPlugin: PHPickerViewControllerDelegate {
    private func sendResults(resultContext: ResultContext, results: Any?) {
        DispatchQueue.main.async {
            resultContext.result(results)
            self.resultContext = nil
            self.fileRepresentation = nil
        }
    }
    
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let resultContext = resultContext else {
            return
        }
        
        // User cancelled.
        if results.isEmpty {
            sendResults(resultContext: resultContext, results: nil)
            return
        }
        
        var outputList: [[String: Any?]] = results.map { ["id": $0.assetIdentifier] }
        if !resultContext.fetchURL {
            sendResults(resultContext: resultContext, results: outputList)
            return
        }
        
        completedTasksCounter = 0
        for (i, res) in results.enumerated() {
            res.itemProvider.loadFileRepresentation(forTypeIdentifier: fileRepresentation ?? UTType.data.identifier) { url, err in
                // This is a separate thread.
                var itemError: String?
                
                if let err = err {
                    itemError = err.localizedDescription
                }
                
                self.taskCounterQueue.async {
                    self.completedTasksCounter += 1
                    outputList[i]["url"] = url?.absoluteString
                    outputList[i]["path"] = url?.path
                    outputList[i]["error"] = itemError
                    
                    if self.completedTasksCounter >= results.count {
                        self.sendResults(resultContext: resultContext, results: outputList)
                        return
                    }
                }
            }
        }
    }
}

extension SwiftPhPickerViewControllerPlugin: UIAdaptivePresentationControllerDelegate {
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        resultContext?.result(nil)
        self.resultContext = nil
    }
}

// Parsing logic.
extension SwiftPhPickerViewControllerPlugin {
    func filterFromString(s: String) throws -> PHPickerFilter {
        switch s {
        case "bursts":
            if #available(iOS 16.0, *) {
                return PHPickerFilter.bursts
            } else {
                throw PluginArgumentError("bursts filter requires iOS 16.0")
            }
        case "cinematicVideos":
            if #available(iOS 16.0, *) {
                return PHPickerFilter.cinematicVideos
            } else {
                throw PluginArgumentError("cinematicVideos filter requires iOS 16.0")
            }
        case "depthEffectPhotos":
            if #available(iOS 16.0, *) {
                return PHPickerFilter.depthEffectPhotos
            } else {
                throw PluginArgumentError("depthEffectPhotos filter requires iOS 16.0")
            }
        case "images":
            return PHPickerFilter.images
        case "livePhotos":
            return PHPickerFilter.livePhotos
        case "panoramas":
            if #available(iOS 15.0, *) {
                return PHPickerFilter.panoramas
            } else {
                throw PluginArgumentError("panoramas filter requires iOS 15.0")
            }
        case "screenRecordings":
            if #available(iOS 15.0, *) {
                return PHPickerFilter.screenRecordings
            } else {
                throw PluginArgumentError("screenRecordings filter requires iOS 15.0")
            }
        case "screenshots":
            if #available(iOS 15.0, *) {
                return PHPickerFilter.screenshots
            } else {
                throw PluginArgumentError("screenshots filter requires iOS 15.0")
            }
        case "slomoVideos":
            if #available(iOS 15.0, *) {
                return PHPickerFilter.slomoVideos
            } else {
                throw PluginArgumentError("slomoVideos filter requires iOS 15.0")
            }
        case "timelapseVideos":
            if #available(iOS 15.0, *) {
                return PHPickerFilter.timelapseVideos
            } else {
                throw PluginArgumentError("timelapseVideos filter requires iOS 15.0")
            }
        case "videos":
            return PHPickerFilter.videos
        default:
            throw PluginArgumentError("Unknown filter name \(s)")
        }
    }
    
    func parseRepresentationMode(s: String) throws -> PHPickerConfiguration.AssetRepresentationMode {
        switch s {
        case "automatic":
            return .automatic
        case "compatible":
            return .compatible
        case "current":
            return .current
        default:
            throw PluginArgumentError("Unknown enum value for PHPickerConfigurationAssetRepresentationMode: \(s)")
        }
    }
    
    @available(iOS 15.0, *)
    func parseSelection(s: String) throws -> PHPickerConfiguration.Selection {
        switch s {
        case "def":
            return .default
        case "ordered":
            return .ordered
        default:
            throw PluginArgumentError("Unknown enum value for Selection: \(s)")
        }
    }
}

extension UIApplication {
    func findKeyWindow() -> UIWindow? {
        if #available(iOS 15.0, *) {
            return UIApplication
                .shared
                .connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .last
        } else if #available(iOS 13.0, *) {
            return UIApplication
                .shared
                .connectedScenes
                .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
                .last { $0.isKeyWindow }
        } else {
            return UIApplication.shared.windows.last { $0.isKeyWindow }
        }
    }
}
