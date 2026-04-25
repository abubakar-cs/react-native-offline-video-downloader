import AVFoundation
import Foundation
import Network
import React
import MMKV

enum PlaybackMode {
    case online
    case offline
}

enum StreamType {
    case separateAudioVideo
    case muxedVideoAudio
    case unknown
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

class VideoDownloadManager: NSObject {
    
    weak var eventEmitter: RCTEventEmitter?
    
    private static var sharedInstance: VideoDownloadManager?
    var backgroundCompletionHandler: (() -> Void)?
        
    private var downloadSession: AVAssetDownloadURLSession?
    private var delegateDispatchQueue: DispatchQueue?
    private var activeDownloads: [String: AVAssetDownloadTask] = [:]
    private var downloadProgress: [String: DownloadProgressInfo] = [:]
    private var incompleteDownloads: Set<String> = []
    private var mmkv: MMKV!
    private let partialDownloadsKey = "PartialDownloads"

        
    private var offlineRegistry: OfflineVideoRegistry
    private var videoQualityManager: VideoQualityManager
    private var progressTracker: DownloadProgressTracker
    private var progressTimers: [String: Timer] = [:]
    private let progressUpdateInterval: TimeInterval = 1.0
        
    private var playbackMode: PlaybackMode = .online
    private var cachedSizes: [String: Int64] = [:]
    private var storedTrackIdentifiers: [String: [Int: TrackIdentifier]] = [:]
    private var downloadToTrackMapping: [String: TrackIdentifier] = [:]
    
    private var isJavascriptLoaded = false
    
    private let networkMonitor = NWPathMonitor()
    private var isNetworkAvailable = true
        
    // MARK: - Data Structures
    
    @objc static func getSharedInstance() -> VideoDownloadManager? {
        return sharedInstance
    }
       
    @objc static func setSharedInstance(_ instance: VideoDownloadManager) {
        if sharedInstance == nil {
            sharedInstance = instance
        } else {
            sharedInstance?.eventEmitter = instance.eventEmitter
        }
    }
    
    struct TrackIdentifier {
        let height: Int
        let width: Int
        let bitrate: Int
        let actualSizeBytes: Int64
        let variant: AVAssetVariant?
    }
    
    struct DownloadProgressInfo {
        var percentage: Float = 0.0
        var downloadedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var state: String = "queued"
        var startTime: Date = Date()
    }
    
    override init() {
        offlineRegistry = OfflineVideoRegistry()
        OfflineVideoRegistry.setShared(offlineRegistry)
        
        videoQualityManager = VideoQualityManager()
        progressTracker = DownloadProgressTracker()
        storedTrackIdentifiers = [:]
        downloadToTrackMapping = [:]
        
        super.init()
        
        MMKV.initialize(rootDir: nil)
        mmkv = MMKV(mmapID: "VideoDownloadManager")
        
        loadPersistedDownloadTasks()
        
        VideoDownloadManager.setSharedInstance(self)
        setupNetworkMonitoring()
        setupDownloadSession()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleJavascriptLoad),
            name: NSNotification.Name("RCTJavaScriptDidLoadNotification"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotReload),
            name: NSNotification.Name("RCTJavaScriptWillStartLoadingNotification"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackgroundSessionReady(_:)),
            name: NSNotification.Name("BackgroundDownloadSessionReady"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
    }
        
    deinit {
        progressTimers.values.forEach { $0.invalidate() }
        progressTimers.removeAll()
        networkMonitor.cancel()
        
        if activeDownloads.isEmpty {
            downloadSession?.invalidateAndCancel()
        }
        
        NotificationCenter.default.removeObserver(self)
    }

    private func setupDownloadSession() {
        
        guard downloadSession == nil else { return }
        
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return
        }
            
        let identifier = "\(bundleIdentifier).background-downloads"
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
           
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.networkServiceType = .video
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        
        if #available(iOS 13.0, *) {
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
        }
            
        if #available(iOS 14.0, *) {
            config.multipathServiceType = .handover
        }
        
        let queueLabel = "com.etv.backgroundDownloadDelegateQueue"
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 3
        
        self.delegateDispatchQueue = DispatchQueue(label: queueLabel)
        operationQueue.underlyingQueue = delegateDispatchQueue
        
        downloadSession = AVAssetDownloadURLSession(
            configuration: config,
            assetDownloadDelegate: self,
            delegateQueue: operationQueue
        )
            
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) {
            self.checkForOrphanedDownloads()
        }
    }
    
    @objc private func handleJavascriptLoad() {
        isJavascriptLoaded = true
    }
    
    @objc private func handleHotReload() {
        
        isJavascriptLoaded = false
    }
    
    @objc private func appWillEnterForeground() {
        
        for (_, downloadTask) in activeDownloads {
            if downloadTask.state == .running {
                downloadTask.suspend()
                downloadTask.resume()
            }
        }
    }

    private func persistDownloadTask(
        downloadId: String,
        masterUrl: String,
        selectedHeight: Int,
        selectedWidth: Int,
        taskIdentifier: UInt
    ) {
        var taskData: [String: Any] = [
            "downloadId": downloadId,
            "masterUrl": masterUrl,
            "selectedHeight": selectedHeight,
            "selectedWidth": selectedWidth,
            "taskIdentifier": taskIdentifier,
            "timestamp": Date().timeIntervalSince1970,
            "state": "active"
        ]
        
        if let track = downloadToTrackMapping[downloadId] {
            taskData["expectedSizeBytes"] = track.actualSizeBytes
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: taskData)
            mmkv.set(jsonData, forKey: "download_\(downloadId)")
        } catch {
            print("Failed to persist task: \(error)")
        }
    }

    private func loadPersistedDownloadTasks() {
        let allKeys = mmkv.allKeys()
        
        if allKeys.isEmpty {
            return
        }
        
        var loadedCount = 0
        
        for key in allKeys {
            if let keyString = key as? String, keyString.hasPrefix("download_") {
                if let data = mmkv.data(forKey: keyString) {
                    do {
                        if let taskData = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let downloadId = taskData["downloadId"] as? String {
                            
                            // Mark as incomplete until we verify with iOS
                            incompleteDownloads.insert(downloadId)
                            loadedCount += 1
                        }
                    } catch {
                        print("Failed to decode task data for key: \(keyString)")
                    }
                }
            }
        }
    }


    private func updatePersistedTaskState(downloadId: String, state: String) {
        if let data = mmkv.data(forKey: "download_\(downloadId)") {
            do {
                if var taskData = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    taskData["state"] = state
                    taskData["lastUpdated"] = Date().timeIntervalSince1970
                    
                    let updatedData = try JSONSerialization.data(withJSONObject: taskData)
                    mmkv.set(updatedData, forKey: "download_\(downloadId)")
                }
            } catch {
                print("Failed to update task state: \(error)")
            }
        }
    }

    private func removePersistedTask(downloadId: String) {
        mmkv.removeValue(forKey: "download_\(downloadId)")
    }
    
    // MARK: - Partial Download Support

    private func savePartialDownload(downloadId: String, location: URL, options: [String: Any]?) {
        let fileManager = FileManager.default
        
        var cleanPath = location.path
        if cleanPath.hasPrefix("/.nofollow/") {
            cleanPath = String(cleanPath.dropFirst("/.nofollow".count))
        }
        
        let cleanURL = URL(fileURLWithPath: cleanPath)
        
        var isDirectory: ObjCBool = false
        let existsAtLocation = fileManager.fileExists(atPath: cleanURL.path, isDirectory: &isDirectory)
        
        if existsAtLocation {
            
            let partialInfo: [String: Any] = [
                "absolutePath": cleanURL.absoluteString,
                "relativePath": cleanURL.path,
                "downloadId": downloadId,
                "savedAt": Date().timeIntervalSince1970,
                "options": options ?? [:],
                "fileSize": getFileSize(at: cleanURL)
            ]
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: partialInfo),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                mmkv.set(jsonString, forKey: "partial_\(downloadId)")
            }
            
            return
        }
        
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let libraryPath = documentsPath.deletingLastPathComponent().appendingPathComponent("Library")
        
        do {
            let libraryContents = try fileManager.contentsOfDirectory(
                at: libraryPath,
                includingPropertiesForKeys: nil,
                options: []
            )
            
            for item in libraryContents where item.lastPathComponent.hasPrefix("com.apple.UserManagedAssets.") {
                let assetContents = try fileManager.contentsOfDirectory(
                    at: item,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                
                for assetItem in assetContents where assetItem.pathExtension == "movpkg" {
                    if assetItem.lastPathComponent.hasPrefix(downloadId) {
                        
                        let partialInfo: [String: Any] = [
                            "absolutePath": assetItem.absoluteString,
                            "relativePath": assetItem.path,
                            "downloadId": downloadId,
                            "savedAt": Date().timeIntervalSince1970,
                            "options": options ?? [:],
                            "fileSize": getFileSize(at: assetItem)
                        ]
                        
                        if let jsonData = try? JSONSerialization.data(withJSONObject: partialInfo),
                           let jsonString = String(data: jsonData, encoding: .utf8) {
                            mmkv.set(jsonString, forKey: "partial_\(downloadId)")
                        }
                        return
                    }
                }
            }
        } catch {
            print("Error searching for partial file: \(error)")
        }  
    }

    private func resumePartialDownloads() {
        guard let allKeys = mmkv.allKeys() as? [String] else {
            return
        }
        
        let partialKeys = allKeys.filter { $0.hasPrefix("partial_") && !$0.contains("partial_abs_") }
        
        if partialKeys.isEmpty {
            return
        }
        
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        var resumedCount = 0
        
        for key in partialKeys {
            let downloadId = String(key.dropFirst("partial_".count))
            
            guard let jsonString = mmkv.string(forKey: key),
                  let jsonData = jsonString.data(using: .utf8),
                  let partialInfo = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let relativePath = partialInfo["relativePath"] as? String else {
                mmkv.removeValue(forKey: key)
                continue
            }
            
            let partialURL = documentsDirectory.appendingPathComponent(relativePath)
            
            // Check if file/directory exists
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: partialURL.path, isDirectory: &isDirectory)
            
            guard exists else {
                // Try absolute path as fallback
                if let absolutePath = partialInfo["absolutePath"] as? String,
                   let absoluteURL = URL(string: absolutePath),
                   fileManager.fileExists(atPath: absoluteURL.path) {
                    resumePartialDownloadFrom(url: absoluteURL, downloadId: downloadId)
                    resumedCount += 1
                    continue
                }
                
                mmkv.removeValue(forKey: key)
                continue
            }

            resumePartialDownloadFrom(url: partialURL, downloadId: downloadId)
            resumedCount += 1
        }
    }

    private func resumePartialDownloadFrom(url: URL, downloadId: String) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            mmkv.removeValue(forKey: "partial_\(downloadId)")
            return
        }
        
        
        let partialAsset = AVURLAsset(url: url)
        var downloadOptions: [String: Any]? = nil
        
        if let jsonString = mmkv.string(forKey: "partial_\(downloadId)"),
           let jsonData = jsonString.data(using: .utf8),
           let partialInfo = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let savedOptions = partialInfo["options"] as? [String: Any] {
            downloadOptions = savedOptions
        }
        
        // Create task with original options
        guard let downloadTask = downloadSession?.makeAssetDownloadTask(
            asset: partialAsset,
            assetTitle: downloadId,
            assetArtworkData: nil,
            options: downloadOptions
        ) else {
            return
        }
        
        downloadTask.taskDescription = downloadId
        activeDownloads[downloadId] = downloadTask
        downloadProgress[downloadId] = DownloadProgressInfo(state: "downloading")
        
        downloadTask.resume()
        startProgressReporting(for: downloadId)
        
        
        guard self.isJavascriptLoaded else {
            print("⏳ Waiting for JS to load before emitting")
            return
        }
        
        DispatchQueue.main.async {
            self.eventEmitter?.sendEvent(withName: "DownloadProgress", body: [
                "downloadId": downloadId,
                "state": "downloading",
                "progress": 0,
                "message": "Resuming from partial download"
            ])
        }
    }

    private func removePartialDownload(downloadId: String) {
        mmkv.removeValue(forKey: "partial_\(downloadId)")
        mmkv.removeValue(forKey: "partial_abs_\(downloadId)")
    }


    private func getAllPersistedTasks() -> [[String: Any]] {
        var tasks: [[String: Any]] = []
        
        let allKeys = mmkv.allKeys()
        
        for key in allKeys {
            if let keyString = key as? String, keyString.hasPrefix("download_") {
                if let data = mmkv.data(forKey: keyString),
                   let taskData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    tasks.append(taskData)
                }
            }
        }
        
        return tasks
    }
    
    private func restorePendingDownloads() {
        
        guard let session = downloadSession else {
            return
        }
        
        // Load persisted task metadata
        let persistedTasks = getAllPersistedTasks()
        
        session.getAllTasks { [weak self] tasks in
            guard let self = self else { return }
            
            Thread.sleep(forTimeInterval: 0.1)
            
            DispatchQueue.main.async {
                
                var restoredCount = 0
                var processedDownloadIds = Set<String>()
                
                for task in tasks {
                    guard let downloadTask = task as? AVAssetDownloadTask else {
                        continue
                    }
                    
                    var downloadId = downloadTask.taskDescription
                    
                    if downloadId == nil || downloadId?.isEmpty == true {
                        let taskId = downloadTask.taskIdentifier
                        
                        for persistedTask in persistedTasks {
                            if let savedId = persistedTask["downloadId"] as? String,
                               let savedTaskId = persistedTask["taskIdentifier"] as? UInt,
                               savedTaskId == taskId,
                               !processedDownloadIds.contains(savedId) {
                                downloadId = savedId
                                break
                            }
                        }
                        
                        if downloadId == nil || downloadId?.isEmpty == true {
                            for persistedTask in persistedTasks {
                                if let savedId = persistedTask["downloadId"] as? String,
                                   !processedDownloadIds.contains(savedId) {
                                    downloadId = savedId
                                    break
                                }
                            }
                        }
                    }
                    
                    guard let id = downloadId, !id.isEmpty else {
                        downloadTask.cancel()
                        continue
                    }
                    
                    if processedDownloadIds.contains(id) {
                        continue
                    }
                    processedDownloadIds.insert(id)
                    
                    let taskState = downloadTask.state
                    
                    switch taskState {
                    case .running, .suspended:
                        self.activeDownloads[id] = downloadTask
                        
                        let progress = downloadTask.progress
                        let percentage = progress.totalUnitCount > 0
                            ? (Double(progress.completedUnitCount) / Double(progress.totalUnitCount)) * 100
                            : 0
                        
                        self.downloadProgress[id] = DownloadProgressInfo(
                            percentage: Float(percentage),
                            downloadedBytes: Int64(progress.completedUnitCount),
                            totalBytes: Int64(progress.totalUnitCount),
                            state: taskState == .running ? "downloading" : "stopped"
                        )
                        
                        self.incompleteDownloads.remove(id)
                        
                        if taskState == .running {
                            downloadTask.suspend()
                            downloadTask.resume()
                        } else if taskState == .suspended {
                            downloadTask.resume()
                        }
                        
                        self.updatePersistedTaskState(downloadId: id, state: "active")
                        
                        self.startProgressReporting(for: id)
                        
                        restoredCount += 1
                        
                    case .completed:
                        self.removePersistedTask(downloadId: id)
                        
                    case .canceling:
                        self.removePersistedTask(downloadId: id)
                        
                    @unknown default:
                        print("Unknown state: \(taskState.rawValue)")
                    }
                }
                
                for persistedTask in persistedTasks {
                    if let savedId = persistedTask["downloadId"] as? String,
                       !processedDownloadIds.contains(savedId),
                       self.activeDownloads[savedId] == nil {
                        self.removePersistedTask(downloadId: savedId)
                    }
                }
            }
        }
    }
    
    @objc private func handleBackgroundSessionReady(_ notification: Notification) {
        if let wrapper = notification.object as? CompletionHandlerWrapper {
            self.backgroundCompletionHandler = wrapper.handler
        }
    }
    
    @objc static func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        sharedInstance?.backgroundCompletionHandler = handler
    }
    
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let handler = self.backgroundCompletionHandler {
                handler()
                self.backgroundCompletionHandler = nil
            }
        }
    }
    
    private func getExpectedSizeForDownload(downloadId: String) -> Int64? {
        guard let data = mmkv.data(forKey: "download_\(downloadId)") else {
            return nil
        }

        do {
            if let taskData = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let expected = taskData["expectedSizeBytes"] as? Int64 {
                    return expected
                }
            }
        } catch {
            print("Failed to decode expected size for \(downloadId): \(error)")
        }
        return nil
    }
    
    private func setupNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
        let wasConnected = self?.isNetworkAvailable ?? true
        self?.isNetworkAvailable = path.status == .satisfied
               
        if !wasConnected && self?.isNetworkAvailable == true {
            self?.resumeStalledDownloads()
        } else if self?.isNetworkAvailable == false {
                print("Network disconnected")
            }
        }
           
        let queue = DispatchQueue.global(qos: .background)
        networkMonitor.start(queue: queue)
    }
    
    private func checkForOrphanedDownloads() {
        guard Thread.isMainThread == false else {
            DispatchQueue.global(qos: .utility).async {
                self.checkForOrphanedDownloads()
            }
            return
        }
        
        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let libraryPath = documentsPath.deletingLastPathComponent().appendingPathComponent("Library")
        
        do {
            let libraryContents = try fileManager.contentsOfDirectory(
                at: libraryPath,
                includingPropertiesForKeys: nil,
                options: []
            )
            
            var processedFiles = Set<String>()
            
            for item in libraryContents where item.lastPathComponent.hasPrefix("com.apple.UserManagedAssets.") {
                
                let assetContents = try fileManager.contentsOfDirectory(
                    at: item,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                
                for assetItem in assetContents where assetItem.pathExtension == "movpkg" {
                    let fileName = assetItem.lastPathComponent
                    
                    guard !processedFiles.contains(fileName) else {
                        continue
                    }
                    processedFiles.insert(fileName)
                    
                    if isDownloadComplete(at: assetItem) {
                        if let downloadId = extractDownloadIdFromFilename(fileName) {
                            DispatchQueue.main.async {
                                self.registerOrphanedDownload(downloadId: downloadId, location: assetItem)
                            }
                        }
                    }
                }
            }
            
            
        } catch {
            print("Error checking for orphaned downloads: \(error)")
        }
    }
    
    private func registerOrphanedDownload(downloadId: String, location: URL) {
        let actualSize = getFileSize(at: location)
        guard actualSize > 0 else { return }

        // Do not auto-complete if we still track this as incomplete/active
        if incompleteDownloads.contains(downloadId) || activeDownloads[downloadId] != nil {
            return
        }

        // Resolve expected size (if any) and validate against it
        let expectedSize = getExpectedSizeForDownload(downloadId: downloadId)
        if let expectedSize = expectedSize {
            let tolerance: Double = 0.01
            let lower = Double(expectedSize) * (1.0 - tolerance)
            let upper = Double(expectedSize) * (1.0 + tolerance)

            if !(Double(actualSize) >= lower && Double(actualSize) <= upper) {
                // Size mismatch → treat as partial; do NOT register as completed
                return
            }
        }

        // Decide what totalBytes to report (fallback to actualSize if no expected)
        let resolvedTotalBytes: Int64 = expectedSize ?? actualSize

        offlineRegistry.registerDownload(
            downloadId: downloadId,
            localUrl: location
        ) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.removePersistedTask(downloadId: downloadId)
                self.removePartialDownload(downloadId: downloadId)

                guard self.isJavascriptLoaded else { return }

                DispatchQueue.main.async {
                    self.eventEmitter?.sendEvent(withName: "DownloadProgress", body: [
                        "downloadId": downloadId,
                        "localUri": location.absoluteString,
                        "state": "completed",
                        "progress": 100,
                        "bytesDownloaded": actualSize,
                        "formattedDownloaded": self.formatBytes(actualSize),
                        "totalBytes": resolvedTotalBytes,
                        "formattedTotal": self.formatBytes(resolvedTotalBytes),
                        "isCompleted": true
                    ])
                }
            }
        }
    }

    private func extractDownloadIdFromFilename(_ filename: String) -> String? {
        let components = filename.replacingOccurrences(of: ".movpkg", with: "").split(separator: "_")
        if let firstPart = components.first {
            let downloadId = String(firstPart)
            if downloadId.count == 24 && downloadId.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil {
                return downloadId
            }
        }
        return nil
    }


    private func isDownloadComplete(at url: URL) -> Bool {
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let asset = AVURLAsset(url: url)
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        let isPlayable = asset.isPlayable

        if let downloadId = extractDownloadIdFromFilename(url.lastPathComponent),
           let expectedSize = getExpectedSizeForDownload(downloadId: downloadId) {

            let actualSize = getFileSize(at: url)
            if actualSize <= 0 { return false }

            let tolerance: Double = 0.01
            let lower = Double(expectedSize) * (1.0 - tolerance)
            let upper = Double(expectedSize) * (1.0 + tolerance)

            return durationSeconds > 0 &&
                   isPlayable &&
                   Double(actualSize) >= lower &&
                   Double(actualSize) <= upper &&
                   !incompleteDownloads.contains(downloadId)
        }

        // Fallback for unknown IDs: require playable + non-trivial duration
        return durationSeconds > 0 && isPlayable
    }

    
    func getAvailableTracks(
        masterUrl: String,
        options: NSDictionary?,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        if masterUrl.contains(".movpkg") {
                resolver([
                    "tracks": [],
                    "message": "Local .movpkg file - no track parsing needed"
                ])
                return
            }
        
        DispatchQueue.main.async {
            self.cachedSizes.removeAll()
            
            guard let url = URL(string: masterUrl) else {
                rejecter("INVALID_URL", "Invalid master URL", nil)
                return
            }
            
            let headers = self.extractHeadersFromOptions(options)
            let asset = self.createAsset(from: url, headers: headers)
            
            // Load asset properties
            asset.loadValuesAsynchronously(forKeys: ["variants", "duration", "tracks"]) {
                DispatchQueue.main.async {
                    var error: NSError?
                    let status = asset.statusOfValue(forKey: "variants", error: &error)
                    
                    guard status == .loaded else {
                        rejecter("QUALITY_LOAD_FAILED", error?.localizedDescription ?? "Failed to load stream qualities", nil)
                        return
                    }
                    
                    let streamType = self.detectStreamTypeAdvanced(asset: asset)
                    
                    let allowedQualities = [480, 720, 1080]
                    
                    var totalDurationSec = 0.0
                    
                    // Get duration
                    if asset.statusOfValue(forKey: "duration", error: nil) == .loaded {
                        totalDurationSec = CMTimeGetSeconds(asset.duration)
                    }
                    
                    // Process video variants with segment sampling
                    Task {
                        await self.processVideoVariantsWithSampling(
                            asset: asset,
                            masterUrl: masterUrl,
                            allowedQualities: allowedQualities,
                            totalDurationSec: totalDurationSec,
                            streamType: streamType,
                            headers: headers
                        ) { videoTracks, videoTrackIdentifiers in
                            // Mutate shared maps and resolve on main — parallel `getAvailableTracks`
                            // (chunked queue) otherwise races on `storedTrackIdentifiers` and can crash.
                            DispatchQueue.main.async {
                                var audioTracksMain: [[String: Any]] = []
                                if streamType == .separateAudioVideo {
                                    audioTracksMain = self.processAudioTracks(asset: asset, duration: totalDurationSec)
                                }

                                self.storedTrackIdentifiers[masterUrl] = videoTrackIdentifiers

                                let sortedVideoTracks = videoTracks.sorted { (first, second) -> Bool in
                                    let firstHeight = first["height"] as? Int ?? 0
                                    let secondHeight = second["height"] as? Int ?? 0
                                    return firstHeight > secondHeight
                                }

                                let prefersHevc = VideoQualityManager.isHevcHardwareDecodeSupported()
                                let result: [String: Any] = [
                                    "videoTracks": sortedVideoTracks,
                                    "audioTracks": audioTracksMain,
                                    "duration": totalDurationSec,
                                    "streamType": streamType.description,
                                    "allowedQualities": allowedQualities,
                                    "availableQualityCount": sortedVideoTracks.count,
                                    "deviceHevcHardwareDecodeSupported": prefersHevc,
                                    "devicePreferredDownloadCodec": prefersHevc ? "hevc" : "h264",
                                ]

                                resolver(result)
                            }
                        }
                    }
                }
            }
        }
    }
    
    func downloadStream(
        masterUrl: String,
        downloadId: String,
        selectedHeight: Int,
        selectedWidth: Int,
        options: NSDictionary?,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            
            guard self.isNetworkAvailable else {
                rejecter("NETWORK_UNAVAILABLE", "No network connection available. Please check your internet connection and try again.", nil)
                return
            }
            
            if let existingTask = self.activeDownloads[downloadId] {
                existingTask.cancel()
                self.activeDownloads.removeValue(forKey: downloadId)
            }
                        
            self.checkAndRemoveExistingDownload(downloadId: downloadId)
            
            guard let url = URL(string: masterUrl) else {
                rejecter("INVALID_URL", "Invalid master URL", nil)
                return
            }
            
            let headers = self.extractHeadersFromOptions(options)
            let asset = self.createAsset(from: url, headers: headers)
            
            asset.loadValuesAsynchronously(forKeys: ["variants", "duration"]) {
                DispatchQueue.main.async {
                    var error: NSError?
                    let status = asset.statusOfValue(forKey: "variants", error: &error)
                    
                    guard status == .loaded else {
                        rejecter("PREPARE_ERROR", error?.localizedDescription ?? "Failed to prepare asset", nil)
                        return
                    }
                    
                    // Get stored track identifiers (keys are canonical 480/720/1080 after variant bucketing)
                    let storedTracks = self.storedTrackIdentifiers[masterUrl]
                    let targetTrack = self.pickStoredTrack(
                        storedTracks: storedTracks,
                        preferredHeight: selectedHeight,
                    )

                    guard let track = targetTrack else {
                        rejecter("TRACK_NOT_FOUND", "Target track not found for \(selectedHeight)p", nil)
                        return
                    }

                    guard track.variant != nil else {
                        rejecter("TRACK_NOT_FOUND", "Track variant not available for \(selectedHeight)p", nil)
                        return
                    }
                    
                    // Detect stream type
                    let streamType = self.detectStreamTypeAdvanced(asset: asset)
                    
                    // Configure download options (NO AUDIO SELECTION - it causes crashes)
                    var downloadOptions: [String: Any] = [:]
                    
                    if #available(iOS 14.0, *) {
                        downloadOptions[AVAssetDownloadTaskMinimumRequiredPresentationSizeKey] = CGSize(
                            width: track.width,
                            height: track.height
                        )
                    }
                    
                    // Create download task
                    self.createDownloadTaskWithRetry(
                        asset: asset,
                        downloadId: downloadId,
                        downloadOptions: downloadOptions,
                        track: track,
                        streamType: streamType,
                        masterUrl: masterUrl,
                        selectedHeight: selectedHeight,
                        selectedWidth: selectedWidth,
                        resolver: resolver,
                        rejecter: rejecter
                    )
                }
            }
        }
    }

    
    private func createDownloadTaskWithRetry(
            asset: AVURLAsset,
            downloadId: String,
            downloadOptions: [String: Any],
            track: TrackIdentifier,
            streamType: StreamType,
            masterUrl: String,
            selectedHeight: Int,
            selectedWidth: Int,
            resolver: @escaping RCTPromiseResolveBlock,
            rejecter: @escaping RCTPromiseRejectBlock
        ) {
            guard let downloadTask = downloadSession?.makeAssetDownloadTask(
                asset: asset,
                assetTitle: downloadId,
                assetArtworkData: nil,
                options: downloadOptions.isEmpty ? nil : downloadOptions
            ) else {
                
                guard let retryTask = downloadSession?.makeAssetDownloadTask(
                    asset: asset,
                    assetTitle: downloadId,
                    assetArtworkData: nil,
                    options: downloadOptions.isEmpty ? nil : downloadOptions
                ) else {
                    rejecter("DOWNLOAD_TASK_FAILED", "Failed to create download task", nil)
                    return
                }
                
                self.startDownloadTask(
                    retryTask,
                    downloadId: downloadId,
                    track: track,
                    streamType: streamType,
                    masterUrl: masterUrl,
                    selectedHeight: selectedHeight,
                    selectedWidth: selectedWidth,
                    resolver: resolver
                )
                return
            }
            
            startDownloadTask(
                downloadTask,
                downloadId: downloadId,
                track: track,
                streamType: streamType,
                masterUrl: masterUrl,
                selectedHeight: selectedHeight,
                selectedWidth: selectedWidth,
                resolver: resolver
            )
        }
        
        private func startDownloadTask(
            _ downloadTask: AVAssetDownloadTask,
            downloadId: String,
            track: TrackIdentifier,
            streamType: StreamType,
            masterUrl: String,
            selectedHeight: Int,
            selectedWidth: Int,
            resolver: @escaping RCTPromiseResolveBlock
        ) {
            
            downloadTask.taskDescription = downloadId
            activeDownloads[downloadId] = downloadTask
            downloadProgress[downloadId] = DownloadProgressInfo()
            
            downloadToTrackMapping[downloadId] = track
            
            persistDownloadTask(
                downloadId: downloadId,
                masterUrl: masterUrl,
                selectedHeight: selectedHeight,
                selectedWidth: selectedWidth,
                taskIdentifier: UInt(downloadTask.taskIdentifier)
            )
            
            downloadTask.resume()

            let response: [String: Any] = [
                "downloadId": downloadId,
                "state": "queued",
                "streamType": streamType.description,
                "expectedSize": formatBytes(track.actualSizeBytes),
                "selectedHeight": selectedHeight,
                "selectedWidth": selectedWidth,
                "bitrate": track.bitrate,
                "uri": masterUrl,
            ]

            // Always resolve — do not gate on isJavascriptLoaded (bridgeless can skip JS load notification).
            resolver(response)

            DispatchQueue.main.async {
                self.eventEmitter?.sendEvent(withName: "DownloadProgress", body: [
                    "downloadId": downloadId,
                    "state": "downloading",
                    "progress": 0,
                ])
            }
        }
        
    private func resumeStalledDownloads() {
        DispatchQueue.main.async {
            for (_, downloadTask) in self.activeDownloads {
                if downloadTask.state == .suspended {
                    downloadTask.resume()
                }
            }
        }
    }
    
    func pauseDownload(
        downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        guard let downloadTask = activeDownloads[downloadId] else {
            rejecter("DOWNLOAD_NOT_FOUND", "Download not found: \(downloadId)", nil)
            return
        }
        let currentProgress = downloadProgress[downloadId]?.percentage ?? 0.0
        
        downloadTask.suspend()
        
        downloadProgress[downloadId]?.state = "stopped"
        
        stopProgressReporting(for: downloadId)
        
        guard isJavascriptLoaded else {
            return
        }
        
        DispatchQueue.main.async {
            self.eventEmitter?.sendEvent(withName: "DownloadProgress", body: [
                "downloadId": downloadId,
                "progress": Int(currentProgress),
                "state": "stopped"
            ])
        }
        
        resolver(["downloadId": downloadId, "status": "stopped"])
    }
    
    func resumeDownload(
        downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        guard let downloadTask = activeDownloads[downloadId] else {
            rejecter("DOWNLOAD_NOT_FOUND", "Download not found: \(downloadId)", nil)
            return
        }
        
        if var progressInfo = downloadProgress[downloadId] {
            let currentProgress = progressInfo.percentage
            
            progressInfo.state = "downloading"
            progressInfo.percentage = currentProgress
            downloadProgress[downloadId] = progressInfo
        }
        
        downloadTask.resume()
        
        if progressTimers[downloadId] == nil {
            startProgressReporting(for: downloadId)
        }
        
        guard isJavascriptLoaded else {
            return
        }
        
        let currentProgress = downloadProgress[downloadId]?.percentage ?? 0
        DispatchQueue.main.async {
            self.eventEmitter?.sendEvent(withName: "DownloadProgress", body: [
                "downloadId": downloadId,
                "progress": Int(currentProgress),
                "state": "downloading"
            ])
        }
        
        resolver(["downloadId": downloadId, "status": "downloading"])
    }
    
    func restartIncompleteDownload(
        downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        guard incompleteDownloads.contains(downloadId) else {
            rejecter("NOT_INCOMPLETE", "Download is not marked as incomplete", nil)
            return
        }
        
        // Get persisted task data
        if let data = mmkv.data(forKey: "download_\(downloadId)"),
           let taskData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let masterUrl = taskData["masterUrl"] as? String,
           let selectedHeight = taskData["selectedHeight"] as? Int,
           let selectedWidth = taskData["selectedWidth"] as? Int {
            
            // Remove incomplete marker
            incompleteDownloads.remove(downloadId)
            removePersistedTask(downloadId: downloadId)
            
            // Start fresh download
            downloadStream(
                masterUrl: masterUrl,
                downloadId: downloadId,
                selectedHeight: selectedHeight,
                selectedWidth: selectedWidth,
                options: nil,
                resolver: resolver,
                rejecter: rejecter
            )
        } else {
            rejecter("NO_TASK_DATA", "Cannot restart - original download parameters not found", nil)
        }
    }
    
    func getDownloadState(
        downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        guard let downloadTask = activeDownloads[downloadId] else {
            rejecter("DOWNLOAD_NOT_FOUND", "Download not found: \(downloadId)", nil)
            return
        }
        
        let taskState: String
        switch downloadTask.state {
        case .running:
            taskState = "downloading"
        case .suspended:
            taskState = "stopped"
        case .canceling:
            taskState = "cancelling"
        case .completed:
            taskState = "completed"
        @unknown default:
            taskState = "unknown"
        }
        
        let progressInfo = downloadProgress[downloadId]
        
        let result: [String: Any] = [
            "downloadId": downloadId,
            "state": taskState,
            "progress": progressInfo?.percentage ?? 0.0,
            "downloadedBytes": Double(progressInfo?.downloadedBytes ?? 0),
            "totalBytes": Double(progressInfo?.totalBytes ?? 0)
        ]
        
        resolver(result)
    }
    
    func cancelDownload(
        downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        
        UserDefaults.standard.set(true, forKey: "cancelled_\(downloadId)")
        
        // If download is active, cancel it
        if let downloadTask = activeDownloads[downloadId] {
            downloadTask.cancel()
            activeDownloads.removeValue(forKey: downloadId)
            downloadProgress.removeValue(forKey: downloadId)
            stopProgressReporting(for: downloadId)
        }
        
        removePersistedTask(downloadId: downloadId)
        incompleteDownloads.remove(downloadId)

        offlineRegistry.removeDownload(downloadId: downloadId) { success, _ in
            resolver(success)
        }
    }
    
    func getAllDownloads(
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        let registeredDownloads = offlineRegistry.getAllDownloadedStreams()
        var allDownloads: [[String: Any]] = []

        for (downloadId, progressInfo) in downloadProgress {
            allDownloads.append([
                "downloadId": downloadId,
                "state": progressInfo.state,
                "progress": Int(progressInfo.percentage),
                "bytesDownloaded": progressInfo.downloadedBytes,
                "totalBytes": progressInfo.totalBytes,
                "formattedDownloaded": formatBytes(progressInfo.downloadedBytes),
                "formattedTotal": formatBytes(progressInfo.totalBytes),
                "isCompleted": progressInfo.state == "completed"
            ])
        }

        for download in registeredDownloads {
            guard let downloadId = download["downloadId"] as? String else { continue }

            if allDownloads.contains(where: { ($0["downloadId"] as? String) == downloadId }) {
                continue
            }

            let fileCheck = offlineRegistry.checkFileExists(downloadId: downloadId)
            guard fileCheck.exists else { continue }

            var downloadInfo = download
            downloadInfo["downloadId"] = downloadId
            downloadInfo["state"] = "completed"
            downloadInfo["progress"] = 100
            downloadInfo["isCompleted"] = true
            allDownloads.append(downloadInfo)
        }

        for downloadId in incompleteDownloads {
            if !allDownloads.contains(where: { ($0["downloadId"] as? String) == downloadId }) {
                allDownloads.append([
                    "downloadId": downloadId,
                    "state": "stopped",
                    "progress": 0,
                    "isCompleted": false,
                    "message": "Paused by iOS. Will resume automatically."
                ])
            }
        }

        resolver(allDownloads)
    }

    
    private func getTotalBytes(downloadId: String) -> Int64 {
        if let trackInfo = getStoredTrackInfo(for: downloadId) {
            return trackInfo.actualSizeBytes
        }

        if let expected = getExpectedSizeForDownload(downloadId: downloadId) {
            return expected
        }

        if let progressInfo = downloadProgress[downloadId] {
            return progressInfo.totalBytes
        }

        return 0
    }

    
    private func getFileSize(at url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }

    private func taskStateToString(_ state: URLSessionTask.State) -> String {
        switch state {
        case .running:
            return "downloading"
        case .suspended:
            return "stopped"
        case .completed:
            return "completed"
        case .canceling:
            return "cancelled"
        @unknown default:
            return "unknown"
        }
    }
    
    func urlSession(
        _ session: URLSession,
        aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        didCompleteDownloadingTo location: URL
    ) {
        let downloadId = findDownloadId(for: aggregateAssetDownloadTask)
        guard !downloadId.isEmpty else { return }
        
        stopProgressReporting(for: downloadId)

        let actualFileSize = getFileSize(at: location)
        let totalBytes = getTotalBytes(downloadId: downloadId)

        offlineRegistry.registerDownload(downloadId: downloadId, localUrl: location) { [weak self] success in
            guard let self else { return }
            if success {
                self.removePersistedTask(downloadId: downloadId)
                self.removePartialDownload(downloadId: downloadId)
                self.updateProgressInfo(
                    downloadId: downloadId,
                    progress: 100.0,
                    downloadedBytes: actualFileSize,
                    isCompleted: true
                )
                self.activeDownloads.removeValue(forKey: downloadId)
                self.downloadProgress.removeValue(forKey: downloadId)

                DispatchQueue.main.async {
                    self.eventEmitter?.sendEvent(withName: "DownloadProgress", body: [
                        "downloadId": downloadId,
                        "localUri": location.absoluteString,
                        "state": "completed",
                        "progress": 100,
                        "bytesDownloaded": actualFileSize,
                        "formattedDownloaded": self.formatBytes(actualFileSize),
                        "totalBytes": totalBytes,
                        "formattedTotal": self.formatBytes(totalBytes),
                        "isCompleted": true
                    ])
                }
            }
        }
    }
    
    func getStorageInfo(
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        let storageStats = offlineRegistry.getStorageStats()
        resolver(storageStats)
    }
    
    func syncDownloadProgress(
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        restorePendingDownloads()
        resumePartialDownloads()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let activeCount = self.activeDownloads.count
            let incompleteCount = self.incompleteDownloads.count
            let allDownloads = self.offlineRegistry.getAllDownloadedStreams()
            let completedCount = allDownloads.count
            let totalCount = activeCount + completedCount + incompleteCount
            
            let result: [String: Any] = [
                "totalDownloads": totalCount,
                "activeDownloads": activeCount,
                "completedDownloads": completedCount,
                "incompleteDownloads": incompleteCount,
                "restoredDownloads": activeCount,
                "downloads": allDownloads
            ]
            
            resolver(result)
        }
    }
    
    func testOfflinePlayback(
        playbackUrl: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        let isCached = offlineRegistry.isContentCached(url: playbackUrl)
        let isDownloaded = offlineRegistry.isContentDownloaded(url: playbackUrl)
            
        let debugInfo: [String: Any] = [
            "url": playbackUrl,
            "dataSourceDetection": isCached,
            "pluginDetection": isDownloaded,
            "registryInitialized": true
        ]
            
        resolver(debugInfo)
    }
    
    // MARK: - Private Helper Methods
    
    private func createAsset(from url: URL, headers: [String: String]?) -> AVURLAsset {
        var options: [String: Any] = [:]
        
        if let headers = headers, !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        
        return AVURLAsset(url: url, options: options.isEmpty ? nil : options)
    }

    
    private func extractHeadersFromOptions(_ options: NSDictionary?) -> [String: String]? {
        guard let opts = options as? [String: Any],
              let headers = opts["headers"] as? [String: String] else {
            return nil
        }
        return headers
    }
    
    /// Maps real presentation heights (540, 716, 864, …) to canonical tiers the JS layer requests (480/720/1080).
    private func canonicalQualityTier(forPresentationHeight height: Int) -> Int? {
        guard height >= 180 else { return nil }
        if height < 560 { return 480 }
        if height < 960 { return 720 }
        return 1080
    }

    /// Picks a stored `TrackIdentifier` for the requested height with small tolerance and bitrate fallback.
    private func pickStoredTrack(
        storedTracks: [Int: TrackIdentifier]?,
        preferredHeight: Int,
    ) -> TrackIdentifier? {
        guard let tracks = storedTracks, !tracks.isEmpty else { return nil }
        if let t = tracks[preferredHeight] { return t }
        let keys = tracks.keys.sorted()
        if let k = keys.last(where: { $0 <= preferredHeight + 48 }), let t = tracks[k] { return t }
        if let k = keys.first(where: { $0 >= preferredHeight - 48 }), let t = tracks[k] { return t }
        return keys.compactMap { tracks[$0] }.max(by: { $0.bitrate < $1.bitrate })
    }

    private func detectStreamTypeAdvanced(asset: AVURLAsset) -> StreamType {
        let hasAudioRenditions = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) != nil
        
        let hasVideoOnlyVariants = asset.variants.contains { variant in
            variant.videoAttributes != nil && variant.audioAttributes == nil
        }
        
        let hasMuxedVariants = asset.variants.contains { variant in
            variant.videoAttributes != nil && variant.audioAttributes != nil
        }
        
        if hasAudioRenditions && hasVideoOnlyVariants {
            return .separateAudioVideo
        }
        
        if hasMuxedVariants && !hasVideoOnlyVariants {
            return .muxedVideoAudio
        }
        
        return .unknown
    }
    
    /// When the manifest lists both HEVC and H.264, keep only renditions matching the device policy (HEVC if hardware-supported, else H.264).
    private func filterVariantsForDownloadPolicy(_ variants: [AVAssetVariant], preferHevc: Bool) -> [AVAssetVariant] {
        let candidates = variants.filter { variant in
            guard variant.videoAttributes != nil else { return false }
            if videoQualityManager.isDolbyVisionVariant(variant) { return false }
            return true
        }
        if preferHevc {
            let hevc = candidates.filter { videoQualityManager.isHevcVariant($0) }
            if !hevc.isEmpty { return hevc }
            let avc = candidates.filter { videoQualityManager.isH264Variant($0) }
            return avc.isEmpty ? candidates : avc
        } else {
            let avc = candidates.filter { videoQualityManager.isH264Variant($0) }
            if !avc.isEmpty { return avc }
            let hevc = candidates.filter { videoQualityManager.isHevcVariant($0) }
            return hevc.isEmpty ? candidates : hevc
        }
    }
    
   private func processVideoVariantsWithSampling(
    asset: AVURLAsset,
    masterUrl: String,
    allowedQualities: [Int],
    totalDurationSec: Double,
    streamType: StreamType,
    headers: [String: String]?,
    completion: @escaping ([[String: Any]], [Int: TrackIdentifier]) -> Void
    ) async {
        var videoTracks: [[String: Any]] = []
        var videoTrackIdentifiers: [Int: TrackIdentifier] = [:]
        
        let preferHevc = VideoQualityManager.isHevcHardwareDecodeSupported()
        let workingVariants = filterVariantsForDownloadPolicy(asset.variants, preferHevc: preferHevc)
        
        for variant in workingVariants {
            guard let videoAttributes = variant.videoAttributes else { continue }
            
            let height = Int(videoAttributes.presentationSize.height)
            let width = Int(videoAttributes.presentationSize.width)
            
            let peakBitRate = variant.peakBitRate ?? 0
            let averageBitRate = variant.averageBitRate ?? 0
            let bitrate = Int(averageBitRate > 0 ? averageBitRate : peakBitRate)
            
            guard bitrate > 0 else { continue }
            
            if videoQualityManager.isDolbyVisionVariant(variant) {
                continue
            }

            guard let tierKey = canonicalQualityTier(forPresentationHeight: height), bitrate > 0 else {
                continue
            }

            let expectedMinBitrate = getMinExpectedBitrate(height: height)
            let isProbablyIFrame = bitrate < expectedMinBitrate

            if !isProbablyIFrame {
                // Keep best bitrate per canonical tier (not raw presentation height)
                if let existingTrack = videoTrackIdentifiers[tierKey],
                   bitrate <= existingTrack.bitrate {
                    continue
                }

                let estimatedSizeBytes = await calculateSizeWithSegmentSampling(
                    variant: variant,
                    masterUrl: masterUrl,
                    duration: totalDurationSec,
                    streamType: streamType,
                    headers: headers
                )

                let trackIdentifier = TrackIdentifier(
                    height: height,
                    width: width,
                    bitrate: bitrate,
                    actualSizeBytes: estimatedSizeBytes,
                    variant: variant
                )

                videoTrackIdentifiers[tierKey] = trackIdentifier

                let codecFamily: String = videoQualityManager.isHevcVariant(variant)
                    ? "hevc"
                    : (videoQualityManager.isH264Variant(variant) ? "h264" : "other")
                let trackData: [String: Any] = [
                    "height": tierKey,
                    "width": width,
                    "bitrate": bitrate,
                    "size": Double(estimatedSizeBytes),
                    "formattedSize": formatBytes(estimatedSizeBytes),
                    "trackId": "\(tierKey)x\(width)x\(bitrate)_src\(height)",
                    "quality": "\(tierKey)p",
                    "streamType": streamType.description,
                    "codec": videoQualityManager.codecTypeToString(videoAttributes.codecTypes.first ?? 0),
                    "codecFamily": codecFamily,
                ]

                videoTracks.removeAll { track in
                    (track["height"] as? Int) == tierKey
                }

                videoTracks.append(trackData)
            }
        }
        
        completion(videoTracks, videoTrackIdentifiers)
    }

    
    private func calculateSizeWithSegmentSampling(
        variant: AVAssetVariant,
        masterUrl: String,
        duration: Double,
        streamType: StreamType,
        headers: [String: String]?
    ) async -> Int64 {
        if let sampledSize = await performSegmentSampling(
            variant: variant,
            masterUrl: masterUrl,
            headers: headers
        ) {
            return sampledSize
        }
        
        // Fallback to bitrate calculation
        return calculateAccurateStreamSize(
            variant: variant,
            duration: duration,
            streamType: streamType,
            headers: headers
        )
    }
    
    private func performSegmentSampling(
        variant: AVAssetVariant,
        masterUrl: String,
        headers: [String: String]?
    ) async -> Int64? {
        
        do {
            guard let variantURL = await getVariantPlaylistURL(
                from: variant,
                masterUrl: masterUrl,
                headers: headers
            ) else {
                return nil
            }
            
            let sampledBytes = try await sampleSegments(
                playlistURL: variantURL,
                headers: headers,
                sampleCount: 8
            )
            
            return sampledBytes
            
        } catch {
            return nil
        }
    }
    
    private func getVariantPlaylistURL(
        from variant: AVAssetVariant,
        masterUrl: String,
        headers: [String: String]?
    ) async -> URL? {
        do {
            guard let masterURL = URL(string: masterUrl) else {
                return nil
            }
            let masterContent = try await downloadPlaylist(url: masterURL, headers: headers)
            guard !masterContent.isEmpty else {
                return nil
            }
            
            let lines = masterContent.components(separatedBy: .newlines)
            var foundVariantLine = false
            
            for i in 0..<lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    if line.contains("BANDWIDTH=\(variant.peakBitRate ?? 0)") ||
                       line.contains("AVERAGE-BANDWIDTH=\(variant.averageBitRate ?? 0)") {
                        foundVariantLine = true
                        continue
                    }
                }
                
                if foundVariantLine && !line.hasPrefix("#") && !line.isEmpty {
                    let variantURLString = line.hasPrefix("http") ? line : resolveURL(base: masterUrl, relative: line)
                    return URL(string: variantURLString)
                }
            }
            
        } catch {
            print("Failed to parse master playlist: \(error)")
        }
        
        return nil
    }

    private func sampleSegments(
        playlistURL: URL,
        headers: [String: String]?,
        sampleCount: Int
    ) async throws -> Int64 {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let playlist = try await downloadPlaylist(url: playlistURL, headers: headers)
                    let segments = parseSegmentURLs(playlist: playlist, baseURL: playlistURL.absoluteString)
                    
                    guard !segments.isEmpty else {
                        continuation.resume(returning: 0)
                        return
                    }
                    
                    let sampleIndices = distributeIndices(total: segments.count, sampleCount: sampleCount)
                    var segmentSizes: [Int64] = []
                    
                    await withTaskGroup(of: Int64.self) { group in
                        for index in sampleIndices.prefix(sampleCount) {
                            group.addTask {
                                do {
                                    return try await self.getSegmentSize(url: segments[index], headers: headers)
                                } catch {
                                    return 0
                                }
                            }
                        }
                        
                        for await size in group {
                            if size > 0 {
                                segmentSizes.append(size)
                            }
                        }
                    }
                    
                    if segmentSizes.isEmpty {
                        continuation.resume(returning: 0)
                        return
                    }
                    
                    let avgSize = segmentSizes.reduce(0, +) / Int64(segmentSizes.count)
                    let totalSize = avgSize * Int64(segments.count)
                    
                    continuation.resume(returning: totalSize)
                    
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func downloadPlaylist(url: URL, headers: [String: String]?) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        
        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "SegmentSampling", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            ])
        }
        
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseSegmentURLs(playlist: String, baseURL: String) -> [String] {
        let lines = playlist.components(separatedBy: .newlines)
        var segments: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                let segmentURL = trimmed.hasPrefix("http") ? trimmed : resolveURL(base: baseURL, relative: trimmed)
                segments.append(segmentURL)
            }
        }
        
        return segments
    }

    private func getSegmentSize(url: String, headers: [String: String]?) async throws -> Int64 {
        guard let segmentURL = URL(string: url) else { return 0 }
        
        var request = URLRequest(url: segmentURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5.0
        
        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return 0 }
        
        return httpResponse.expectedContentLength > 0 ? httpResponse.expectedContentLength : 0
    }

    private func distributeIndices(total: Int, sampleCount: Int) -> [Int] {
        guard total > sampleCount else {
            return Array(0..<total)
        }
        
        var indices: [Int] = []
        
        switch sampleCount {
        case 8:
            indices.append(0)                            // Start
            indices.append(Int(Double(total) * 0.125))   // 12.5%
            indices.append(Int(Double(total) * 0.25))    // 25%
            indices.append(Int(Double(total) * 0.375))   // 37.5%
            indices.append(Int(Double(total) * 0.5))     // 50%
            indices.append(Int(Double(total) * 0.625))   // 62.5%
            indices.append(Int(Double(total) * 0.75))    // 75%
            indices.append(total - 1)                    // End
        default:
            let step = Float(total) / Float(sampleCount)
            for i in 0..<sampleCount {
                let index = Int(Float(i) * step).clamped(to: 0...(total-1))
                indices.append(index)
            }
        }
        
        return Array(Set(indices)).sorted()
    }

    private func resolveURL(base: String, relative: String) -> String {
        if relative.hasPrefix("http") {
            return relative
        }
        
        guard let baseURL = URL(string: base) else { return relative }
        let baseWithoutFile = baseURL.deletingLastPathComponent().absoluteString
        return baseWithoutFile.hasSuffix("/") ? baseWithoutFile + relative : baseWithoutFile + "/" + relative
    }

    
    private func processAudioTracks(asset: AVURLAsset, duration: Double) -> [[String: Any]] {
        var audioTracks: [[String: Any]] = []
        var bestStereoPerLanguage: [String: [String: Any]] = [:]
        
        if let audioGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            for option in audioGroup.options {
                if checkForDolbyAtmos(option: option) {
                    continue
                }
                
                let channelCount = getChannelCount(for: option)
                
                if channelCount > 2 {
                    continue
                }
                
                let language = option.locale?.languageCode ?? "unknown"
                let audioBitrate = 128000
                let estimatedSizeBytes = calculateAudioOnlySize(audioBitrate: audioBitrate, duration: duration)
                
                let audioType = channelCount == 1 ? "mono" : "stereo"
                
                let audioTrackData: [String: Any] = [
                    "language": language,
                    "label": option.displayName.isEmpty ? "Stereo \(language)" : option.displayName,
                    "channelCount": channelCount,
                    "audioType": audioType,
                    "bitrate": audioBitrate,
                    "size": Double(estimatedSizeBytes),
                    "formattedSize": formatBytes(estimatedSizeBytes),
                    "mimeType": "audio/mp4a-latm"
                ]
                
                // Keep best stereo track per language
                if let existing = bestStereoPerLanguage[language],
                let existingBitrate = existing["bitrate"] as? Int,
                audioBitrate > existingBitrate {
                    bestStereoPerLanguage[language] = audioTrackData
                } else if bestStereoPerLanguage[language] == nil {
                    bestStereoPerLanguage[language] = audioTrackData
                }
                
            }
            
            audioTracks = Array(bestStereoPerLanguage.values)
        }
        
        return audioTracks
    }

    private func getChannelCount(for option: AVMediaSelectionOption) -> Int {
        let displayName = option.displayName.lowercased()
        let extendedLanguageTag = option.extendedLanguageTag?.lowercased() ?? ""
        let combinedText = displayName + extendedLanguageTag
        
        // For stereo-only downloads, we cap at 2 channels
        if combinedText.contains("7.1") {
            return 8 // But will be filtered out
        } else if combinedText.contains("5.1") || combinedText.contains("atmos") {
            return 6 // But will be filtered out
        } else if combinedText.contains("surround") {
            return 6 // But will be filtered out
        } else if combinedText.contains("stereo") || combinedText.contains("2.0") {
            return 2
        } else if combinedText.contains("mono") || combinedText.contains("1.0") {
            return 1
        }
        
        return 2
    }


    private func checkForDolbyAtmos(option: AVMediaSelectionOption) -> Bool {
        let displayName = option.displayName.lowercased()
        let extendedLanguageTag = option.extendedLanguageTag?.lowercased() ?? ""
        
        // Check display name for Dolby identifiers
        let dolbyKeywords = ["ddp", "dd+", "dd +", "atmos", "ec-3", "eac3", "eac-3",
                            "ac-3", "ac3", "dolby digital", "dolby", "joc"]
        
        let hasDolbyInName = dolbyKeywords.contains { displayName.contains($0) }
        let hasDolbyInTag = dolbyKeywords.contains { extendedLanguageTag.contains($0) }
        
        // Check using available metadata
        var hasDolbyInMetadata = false
        let commonMetadata = option.commonMetadata
        
        for item in commonMetadata {
            if let key = item.commonKey?.rawValue.lowercased(),
               let value = item.stringValue?.lowercased() {
                if dolbyKeywords.contains(where: { key.contains($0) || value.contains($0) }) {
                    hasDolbyInMetadata = true
                    break
                }
            }
        }
        
        let isDolby = hasDolbyInName || hasDolbyInTag || hasDolbyInMetadata
        
        if isDolby {
            print("⚠️ Filtering Dolby audio: '\(option.displayName)' (lang: \(option.locale?.languageCode ?? "unknown"))")
            print("   - Extended tag: \(extendedLanguageTag)")
        } else {
            print("✅ Accepting stereo audio: '\(option.displayName)' (lang: \(option.locale?.languageCode ?? "unknown"))")
        }
        
        return isDolby
    }

    private func getMinExpectedBitrate(height: Int) -> Int {
        switch height {
        case 144: return 100000
        case 240: return 200000
        case 360: return 400000
        case 480: return 600000
        case 576: return 800000
        case 720: return 1200000
        case 1080: return 2500000
        default: return 100000
        }
    }

    private func calculateAccurateStreamSize(
        variant: AVAssetVariant,
        duration: Double,
        streamType: StreamType,
        headers: [String: String]?
    ) -> Int64 {
        let peakBitrate = variant.peakBitRate ?? 0
        let avgBitrate = variant.averageBitRate ?? 0
        let bitrate = Int64(avgBitrate > 0 ? avgBitrate : peakBitrate)
        
        guard bitrate > 0 && duration > 0 else {
            return estimateSizeFromResolution(variant: variant, duration: duration, streamType: streamType)
        }
        
        // Calculate size based on stream type
        let estimatedSize: Int64
        switch streamType {
        case .separateAudioVideo:
            estimatedSize = calculateVideoOnlySize(videoBitrate: bitrate, duration: duration)
        case .muxedVideoAudio:
            estimatedSize = calculateMuxedStreamSize(combinedBitrate: bitrate, duration: duration)
        case .unknown:
            estimatedSize = calculateVideoOnlySize(videoBitrate: bitrate, duration: duration)
        }
        
        return estimatedSize
    }
    
    private func estimateSizeFromResolution(variant: AVAssetVariant, duration: Double, streamType: StreamType) -> Int64 {
        guard let videoAttributes = variant.videoAttributes else { return 0 }
        
        let height = Int(videoAttributes.presentationSize.height)
        
        let estimatedBitrate: Int64
        switch height {
        case 480:
            estimatedBitrate = 1_000_000  // 1 Mbps
        case 720:
            estimatedBitrate = 3_000_000  // 3 Mbps
        case 1080:
            estimatedBitrate = 6_000_000  // 6 Mbps
        default:
            estimatedBitrate = Int64(height * 2000)
        }
        
        switch streamType {
        case .separateAudioVideo:
            return calculateVideoOnlySize(videoBitrate: estimatedBitrate, duration: duration)
        case .muxedVideoAudio:
            return calculateMuxedStreamSize(combinedBitrate: estimatedBitrate, duration: duration)
        case .unknown:
            return calculateVideoOnlySize(videoBitrate: estimatedBitrate, duration: duration)
        }
    }

    private func calculateVideoOnlySize(videoBitrate: Int64, duration: Double) -> Int64 {
        guard videoBitrate > 0 && duration > 0 else { return 0 }
        
        let rawBits = Double(videoBitrate) * duration
        let rawBytes = rawBits / 8.0
        
        let hlsOverhead = 1.02
        let estimatedBytes = rawBytes * hlsOverhead
        
        return Int64(estimatedBytes)
    }
    
    private func calculateMuxedStreamSize(combinedBitrate: Int64, duration: Double) -> Int64 {
        guard combinedBitrate > 0 && duration > 0 else { return 0 }
        
        let rawBits = Double(combinedBitrate) * duration
        let rawBytes = rawBits / 8.0
        
        let hlsOverhead = 1.02
        let estimatedBytes = rawBytes * hlsOverhead
        
        return Int64(estimatedBytes)
    }
    
    private func calculateAudioOnlySize(audioBitrate: Int, duration: Double) -> Int64 {
        guard audioBitrate > 0 && duration > 0 else { return 0 }
        
        let audioBits = Double(audioBitrate) * duration
        let audioBytes = audioBits / 8.0 * 1.02
        
        return Int64(audioBytes)
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func startProgressReporting(for downloadId: String) {
        // Timers must use the main run loop; this is often invoked from the URLSession delegate queue.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopProgressReporting(for: downloadId)
            let timer = Timer.scheduledTimer(withTimeInterval: self.progressUpdateInterval, repeats: true) { [weak self] _ in
                guard let self,
                      let downloadTask = self.activeDownloads[downloadId] else {
                    self?.stopProgressReporting(for: downloadId)
                    return
                }

                if downloadTask.state == .running {
                    if let progressInfo = self.downloadProgress[downloadId] {
                        let isDone = progressInfo.percentage >= 99.5 || progressInfo.state == "completed"
                        self.emitProgressEvent(
                            downloadId: downloadId,
                            progress: progressInfo.percentage,
                            downloadedBytes: progressInfo.downloadedBytes,
                            state: isDone ? "completed" : "downloading",
                        )
                    }
                } else if downloadTask.state == .suspended {
                    // Not running yet — keep timer; AVAssetDownloadTask can sit in suspended briefly.
                    return
                } else {
                    self.stopProgressReporting(for: downloadId)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.progressTimers[downloadId] = timer
        }
    }
        
        private func stopProgressReporting(for downloadId: String) {
            if let timer = progressTimers[downloadId] {
                timer.invalidate()
                progressTimers.removeValue(forKey: downloadId)
            }
        }
        
        private func emitProgressEvent(downloadId: String, progress: Float, downloadedBytes: Int64, state: String) {
            let totalBytes = getTotalBytes(downloadId: downloadId)
            DispatchQueue.main.async {
                self.eventEmitter?.sendEvent(withName: "DownloadProgress", body: [
                    "downloadId": downloadId,
                    "progress": Int(progress),
                    "bytesDownloaded": downloadedBytes,
                    "formattedDownloaded": self.formatBytes(downloadedBytes),
                    "totalBytes": Int64(totalBytes),
                    "formattedTotal": self.formatBytes(totalBytes),
                    "state": state,
                    "isCompleted": state == "completed",
                ])
            }
        }
    
    func getOfflinePlaybackUri(
        downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        if let localUrl = offlineRegistry.getLocalUrl(for: downloadId) {
            resolver([
                "uri": localUrl.absoluteString,
                "isOffline": true
            ])
        } else {
            resolver([
                "uri": "",
                "isOffline": false
            ])
        }
    }

    func isDownloaded(
        downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        let isDownloaded = offlineRegistry.isContentDownloaded(url: downloadId)
        resolver(isDownloaded)
    }

    func getDownloadStatus(
        downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        if let progressInfo = downloadProgress[downloadId] {
            resolver([
                "downloadId": downloadId,
                "state": progressInfo.state,
                "progress": Int(progressInfo.percentage),
                "bytesDownloaded": progressInfo.downloadedBytes,
                "totalBytes": progressInfo.totalBytes,
                "formattedDownloaded": formatBytes(progressInfo.downloadedBytes),
                "formattedTotal": formatBytes(progressInfo.totalBytes),
                "isCompleted": progressInfo.state == "completed"
            ])
            return
        }

        if incompleteDownloads.contains(downloadId) {
            resolver([
                "downloadId": downloadId,
                "state": "stopped",
                "progress": 0,
                "bytesDownloaded": 0,
                "totalBytes": 0,
                "formattedDownloaded": formatBytes(0),
                "formattedTotal": formatBytes(0),
                "isCompleted": false
            ])
            return
        }

        if let localUrl = offlineRegistry.getLocalUrl(for: downloadId) {
            let fileCheck = offlineRegistry.checkFileExists(downloadId: downloadId)
            guard fileCheck.exists else {
                rejecter("DOWNLOAD_NOT_FOUND", "Download file missing for: \(downloadId)", nil)
                return
            }

            resolver([
                "downloadId": downloadId,
                "uri": localUrl.absoluteString,
                "state": "completed",
                "progress": 100,
                "bytesDownloaded": 0,
                "totalBytes": 0,
                "formattedDownloaded": formatBytes(0),
                "formattedTotal": formatBytes(0),
                "isCompleted": true
            ])
            return
        }

        rejecter("DOWNLOAD_NOT_FOUND", "Download not found: \(downloadId)", nil)
    }

    func getVideoCodecDownloadPreference(
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        let hevc = VideoQualityManager.isHevcHardwareDecodeSupported()
        resolver([
            "preferredCodec": hevc ? "hevc" : "h264",
            "hevcHardwareDecodeSupported": hevc,
            "platform": "ios",
        ])
    }

    func checkStorageSpace(
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        let storageInfo = offlineRegistry.getStorageStats()
        let currentCacheSize = storageInfo["totalSize"] as? Double ?? 0
        let availableSpace = storageInfo["availableSpace"] as? Double ?? 0
        let totalCacheSize = storageInfo["maxSize"] as? Double ?? 0
        
        resolver([
            "currentCacheSizeMB": currentCacheSize / (1024 * 1024),
            "availableSpaceMB": availableSpace / (1024 * 1024),
            "totalCacheSizeMB": totalCacheSize / (1024 * 1024),
            "currentCacheFormatted": formatBytes(Int64(currentCacheSize)),
            "availableSpaceFormatted": formatBytes(Int64(availableSpace)),
            "hasEnoughSpace": availableSpace > (2 * 1024 * 1024 * 1024),
            // Preserve legacy keys for existing consumers.
            "totalSize": currentCacheSize,
            "maxSize": totalCacheSize,
            "availableSpace": availableSpace,
            "usedPercentage": storageInfo["usedPercentage"] as? Int ?? 0,
            "path": storageInfo["path"] as? String ?? "",
            "isProtected": storageInfo["isProtected"] as? Bool ?? true,
            "deviceTotalSpace": storageInfo["deviceTotalSpace"] as? Double ?? 0,
            "deviceFreeSpace": storageInfo["deviceFreeSpace"] as? Double ?? 0
        ])
    }

    func canDownloadContent(
        estimatedSizeBytes: Int64,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        let storageInfo = offlineRegistry.getStorageStats()
        let availableSpace = storageInfo["availableSpace"] as? Double ?? 0
        let canDownload = Double(estimatedSizeBytes) <= availableSpace
        
        resolver([
            "canDownload": canDownload,
            "availableSpaceMB": availableSpace / (1024 * 1024),
            "requiredSpaceMB": Double(estimatedSizeBytes) / (1024 * 1024),
            "availableSpaceFormatted": formatBytes(Int64(availableSpace)),
            "requiredSpaceFormatted": formatBytes(estimatedSizeBytes)
        ])
    }

    func isDownloadCached(
        downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        let isCached = offlineRegistry.isContentDownloaded(url: downloadId)
        resolver(isCached)
    }

    func setPlaybackMode(
        mode: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        let modeValue: Int
        switch mode.lowercased() {
        case "offline":
            modeValue = 1
        case "online":
            modeValue = 0
        default:
            rejecter("INVALID_MODE", "Invalid playback mode: \(mode). Use 'online' or 'offline'", nil)
            return
        }
        
        OfflineVideoPlugin.setPlaybackMode(modeValue)
        
        resolver([
            "mode": mode,
            "status": "success"
        ])
    }

    func getPlaybackMode(
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        let currentModeValue = OfflineVideoPlugin.getPlaybackMode()
        let currentMode = currentModeValue == 1 ? "offline" : "online"
        
        resolver([
            "mode": currentMode
        ])
    }

    private func checkAndRemoveExistingDownload(downloadId: String) {
        if let existingTask = activeDownloads[downloadId] {
            existingTask.cancel()
            activeDownloads.removeValue(forKey: downloadId)
            downloadProgress.removeValue(forKey: downloadId)
        }
    }
    
    private func getDownloadsDirectoryPath() -> String {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("downloads").path
    }
}

// MARK: - Extensions for StreamType
extension StreamType {
    var description: String {
        switch self {
        case .separateAudioVideo:
            return "SEPARATE_AUDIO_VIDEO"
        case .muxedVideoAudio:
            return "MUXED_VIDEO_AUDIO"
        case .unknown:
            return "UNKNOWN"
        }
    }
}

// MARK: - AVAssetDownloadDelegate

extension VideoDownloadManager: AVAssetDownloadDelegate {
    
    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        let downloadId = findDownloadId(for: assetDownloadTask)
        guard !downloadId.isEmpty else { return }
        
        handleProgressUpdate(
            downloadId: downloadId,
            timeRange: timeRange,
            loadedTimeRanges: loadedTimeRanges,
            expectedTimeRange: timeRangeExpectedToLoad
        )
        
        if progressTimers[downloadId] == nil {
            startProgressReporting(for: downloadId)
        }
    }
    
    // Download completion
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        let downloadId = findDownloadId(for: assetDownloadTask)
        guard !downloadId.isEmpty else { return }
        
        let wasCancelled = assetDownloadTask.error != nil ||
            (assetDownloadTask.error as NSError?)?.code == NSURLErrorCancelled ||
            UserDefaults.standard.bool(forKey: "cancelled_\(downloadId)")
            
        if wasCancelled {
            UserDefaults.standard.removeObject(forKey: "cancelled_\(downloadId)")
                
            savePartialDownload(downloadId: downloadId, location: location, options: assetDownloadTask.options )
            return
        }
        
        
        let actualFileSize = getFileSize(at: location)
        let totalBytes = getTotalBytes(downloadId: downloadId)
        
        // Register download
        offlineRegistry.registerDownload(downloadId: downloadId, localUrl: location) { [weak self] success in
            guard let self = self else { return }
            
            if success {

                self.removePersistedTask(downloadId: downloadId)
                self.removePartialDownload(downloadId: downloadId)

                self.updateProgressInfo(
                    downloadId: downloadId,
                    progress: 100.0,
                    downloadedBytes: actualFileSize,
                    isCompleted: true
                )

                self.stopProgressReporting(for: downloadId)
                self.activeDownloads.removeValue(forKey: downloadId)
                self.downloadProgress.removeValue(forKey: downloadId)

                DispatchQueue.main.async {
                    self.eventEmitter?.sendEvent(withName: "DownloadProgress", body: [
                        "downloadId": downloadId,
                        "localUri": location.absoluteString,
                        "state": "completed",
                        "progress": 100,
                        "bytesDownloaded": actualFileSize,
                        "formattedDownloaded": self.formatBytes(actualFileSize),
                        "totalBytes": totalBytes,
                        "formattedTotal": self.formatBytes(totalBytes),
                        "isCompleted": true
                    ])
                }

            } else {
                print("Failed to register download: \(downloadId)")
            }
        }
    }
    
    // Download error handling
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let downloadId = findDownloadId(for: task)
        guard !downloadId.isEmpty else { return }
        
        if let error = error {
            stopProgressReporting(for: downloadId)
            activeDownloads.removeValue(forKey: downloadId)
            downloadProgress.removeValue(forKey: downloadId)

            DispatchQueue.main.async {
                self.eventEmitter?.sendEvent(withName: "DownloadProgress", body: [
                    "downloadId": downloadId,
                    "error": error.localizedDescription,
                    "state": "failed"
                ])
            }
        }
    }
    
    func urlSession(_ session: URLSession,
                    aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
                    didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange,
                    for mediaSelection: AVMediaSelection) {

        guard !findDownloadId(for: aggregateAssetDownloadTask).isEmpty else { return }
        let downloadId = findDownloadId(for: aggregateAssetDownloadTask)
        
        handleProgressUpdate(
            downloadId: downloadId,
            timeRange: timeRange,
            loadedTimeRanges: loadedTimeRanges,
            expectedTimeRange: timeRangeExpectedToLoad
        )
    }
    
    private func handleProgressUpdate(
        downloadId: String,
        timeRange: CMTimeRange,
        loadedTimeRanges: [NSValue],
        expectedTimeRange: CMTimeRange
    ) {
        var percentComplete: Float = 0.0
        let totalDuration = CMTimeGetSeconds(expectedTimeRange.duration)
        
        if totalDuration > 0 {
            for value in loadedTimeRanges {
                let loadedTimeRange: CMTimeRange = value.timeRangeValue
                let loadedDuration = CMTimeGetSeconds(loadedTimeRange.duration)
                percentComplete += Float(loadedDuration / totalDuration)
            }
            percentComplete = min(percentComplete * 100, 100.0)
        }
        
        let estimatedBytes = calculateEstimatedBytes(downloadId: downloadId, progress: percentComplete)
        let totalBytes = getTotalBytes(downloadId: downloadId)
        
        updateProgressInfo(downloadId: downloadId, progress: percentComplete, downloadedBytes: estimatedBytes)

        let completed = percentComplete >= 100.0
        DispatchQueue.main.async {
            self.eventEmitter?.sendEvent(withName: "DownloadProgress", body: [
                "downloadId": downloadId,
                "progress": Int(percentComplete),
                "bytesDownloaded": Int64(estimatedBytes),
                "formattedDownloaded": self.formatBytes(estimatedBytes),
                "totalBytes": Int64(totalBytes),
                "formattedTotal": self.formatBytes(totalBytes),
                "state": completed ? "completed" : "downloading",
                "isCompleted": completed
            ])
        }
    }

    private func findDownloadId(for task: URLSessionTask) -> String {
        if let taskDescription = task.taskDescription, !taskDescription.isEmpty {
            return taskDescription
        }
        
        for (downloadId, downloadTask) in activeDownloads {
            if downloadTask.taskIdentifier == task.taskIdentifier {
                return downloadId
            }
        }
        
        if let assetTask = task as? AVAssetDownloadTask {
            let urlString = assetTask.urlAsset.url.absoluteString
            for (downloadId, _) in activeDownloads {
                if urlString.contains(downloadId) {
                    return downloadId
                }
            }
        }
        
        return ""
    }

    
    private func getStoredTrackInfo(for downloadId: String) -> TrackIdentifier? {
        if let trackInfo = downloadToTrackMapping[downloadId] {
            return trackInfo
        }
        
        for (_, trackDict) in storedTrackIdentifiers {
            for (_, track) in trackDict {
                return track
            }
        }
        
        return nil
    }

    
    private func calculateEstimatedBytes(downloadId: String, progress: Float) -> Int64 {
        if let trackInfo = getStoredTrackInfo(for: downloadId) {
            return Int64(Float(trackInfo.actualSizeBytes) * (progress / 100.0))
        }
        
        return Int64(progress * 1024 * 1024)
    }
    
    private func updateProgressInfo(downloadId: String, progress: Float, downloadedBytes: Int64, isCompleted: Bool = false) {
        var progressInfo = downloadProgress[downloadId] ?? DownloadProgressInfo()
        progressInfo.percentage = progress
        progressInfo.downloadedBytes = downloadedBytes
        progressInfo.state = isCompleted ? "completed" : "downloading"
        if progressInfo.totalBytes == 0 {
            progressInfo.totalBytes = getTotalBytes(downloadId: downloadId)
        }
        
        downloadProgress[downloadId] = progressInfo
    }
}
