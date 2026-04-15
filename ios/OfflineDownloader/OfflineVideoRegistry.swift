import Foundation

class OfflineVideoRegistry {
    
    private let userDefaults = UserDefaults.standard
    private let registryKey = "OfflineVideoRegistry"
    private let registryQueue = DispatchQueue(label: "com.offlinevideodownloader.registry", attributes: .concurrent)
       
    static var shared: OfflineVideoRegistry?
    
    init() {
        createDownloadsDirectoryIfNeeded()
    }
        
    static func setShared(_ instance: OfflineVideoRegistry) {
        shared = instance
    }
    
    // MARK: - Public Methods
    
    func registerDownload(downloadId: String, localUrl: URL, completion: @escaping (Bool) -> Void) {
        registryQueue.async(flags: .barrier) {
            var registry = self.getRegistryUnsafe()
                
            let actualFileSize = self.getFileSize(at: localUrl)
                
            registry[downloadId] = [
                "localUrl": localUrl.absoluteString,
                "downloadDate": Date().timeIntervalSince1970,
                "fileSize": actualFileSize,
                "formattedSize": self.formatBytes(actualFileSize)
            ]
                
            self.saveRegistryUnsafe(registry)

            DispatchQueue.main.async {
                completion(true)
            }
        }
    }
    
    func removeDownload(downloadId: String, completion: @escaping (Bool, String?) -> Void) {
        registryQueue.async(flags: .barrier) {
            let registry = self.getRegistryUnsafe()
            var localUrl: URL?

            if let data = registry[downloadId],
               let urlString = data["localUrl"] as? String,
               let url = URL(string: urlString) {
                localUrl = url
            } else if let resolved = self.getLocalUrlUnsafe(for: downloadId) {
                localUrl = resolved
            }

            if let url = localUrl, FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    print("Failed to remove file (continuing): \(error)")
                }
            }

            // Always drop the registry row for this id so UI cannot show "downloaded" after delete/cancel
            // when the file is already gone or the URL string no longer parses.
            self.removeFromRegistryUnsafe(downloadId: downloadId)

            DispatchQueue.main.async {
                completion(true, nil)
            }
        }
    }
        
    func getAllDownloadedStreams() -> [[String: Any]] {
        var result: [[String: Any]] = []
            
        registryQueue.sync {
            let registry = self.getRegistryUnsafe()
                
            for (downloadId, data) in registry {
                guard let urlString = data["localUrl"] as? String else {
                    continue
                }
                    
                result.append([
                    "downloadId": downloadId,
                    "localUri": urlString,
                    "downloadDate": data["downloadDate"] as? TimeInterval ?? 0,
                    "fileSize": data["fileSize"] as? Int64 ?? 0,
                    "formattedSize": data["formattedSize"] as? String ?? "Unknown"
                ])
            }
        }
            
        return result
    }
    
    func isContentCached(url: String) -> Bool {
        var result = false
        
        registryQueue.sync {
            let contentId = self.extractContentId(from: url)
            let registry = self.getRegistryUnsafe()
            
            for (downloadId, data) in registry {
                if let localUrlString = data["localUrl"] as? String {
                    if downloadId == url ||
                       (!contentId.isEmpty && downloadId.contains(contentId)) ||
                       (!contentId.isEmpty && localUrlString.contains(contentId)) ||
                       url.contains(downloadId) {
                        result = true
                        break
                    }
                }
            }
        }
        
        return result
    }
    
    func isContentDownloaded(url: String) -> Bool {
        return isContentCached(url: url)
    }
    
    func getStorageStats() -> [String: Any] {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadsPath = documentsPath.appendingPathComponent("downloads")
        
        createDownloadsDirectoryIfNeeded()
        
        let totalSize = getFolderSize(downloadsPath)
        let maxSize: Int64 = 15 * 1024 * 1024 * 1024
        let availableSpace = max(0, maxSize - totalSize)
        let usedPercentage = totalSize > 0 ? min(100, Int((totalSize * 100) / maxSize)) : 0
        
        let deviceStats = getDeviceStorageStats()
        
        return [
            "totalSize": Double(totalSize),
            "maxSize": Double(maxSize),
            "availableSpace": Double(availableSpace),
            "usedPercentage": usedPercentage,
            "path": downloadsPath.path,
            "isProtected": true,
            "deviceTotalSpace": deviceStats.total,
            "deviceFreeSpace": deviceStats.free
        ]
    }
    
    func getLocalUrl(for urlString: String) -> URL? {
        var result: URL?
        
        registryQueue.sync {
            result = self.getLocalUrlUnsafe(for: urlString)
        }
        
        return result
    }
    
    func checkFileExists(downloadId: String) -> (exists: Bool, url: String?) {
        var result: (exists: Bool, url: String?) = (false, nil)
        
        registryQueue.sync {
            let registry = self.getRegistryUnsafe()
            
            if let data = registry[downloadId],
               let urlString = data["localUrl"] as? String,
               let url = URL(string: urlString) {
                
                let exists = FileManager.default.fileExists(atPath: url.path)
                result = (exists: exists, url: urlString)
            }
        }
        
        return result
    }
    
    func manualCleanupMissingFiles() -> Int {
        var cleanedCount = 0
        
        registryQueue.sync(flags: .barrier) {
            let registry = self.getRegistryUnsafe()
            var updatedRegistry = registry
            
            for (downloadId, data) in registry {
                if let urlString = data["localUrl"] as? String,
                   let url = URL(string: urlString) {
                    
                    if !FileManager.default.fileExists(atPath: url.path) {
                        updatedRegistry.removeValue(forKey: downloadId)
                        cleanedCount += 1
                    }
                }
            }
            
            if cleanedCount > 0 {
                self.saveRegistryUnsafe(updatedRegistry)
            }
        }
        
        return cleanedCount
    }
    
    func scanAndRestoreMissingDownloads() -> Int {
        var restoredCount = 0
        
        registryQueue.sync(flags: .barrier) {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let libraryPath = documentsPath.deletingLastPathComponent().appendingPathComponent("Library")
            
            do {
                let libraryContents = try FileManager.default.contentsOfDirectory(
                    at: libraryPath,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                
                var registry = self.getRegistryUnsafe()
                
                for item in libraryContents where item.lastPathComponent.hasPrefix("com.apple.UserManagedAssets.") {
                    let assetContents = try FileManager.default.contentsOfDirectory(
                        at: item,
                        includingPropertiesForKeys: nil,
                        options: []
                    )
                    
                    for assetItem in assetContents where assetItem.pathExtension == "movpkg" {
                        if let downloadId = self.extractDownloadIdFromFilename(assetItem.lastPathComponent),
                           registry[downloadId] == nil {
                            
                            let fileSize = self.getFileSize(at: assetItem)
                            registry[downloadId] = [
                                "localUrl": assetItem.absoluteString,
                                "downloadDate": Date().timeIntervalSince1970,
                                "fileSize": fileSize,
                                "formattedSize": self.formatBytes(fileSize)
                            ]
                            
                            restoredCount += 1
                        }
                    }
                }
                
                if restoredCount > 0 {
                    self.saveRegistryUnsafe(registry)
                }
                
            } catch {
                print("Error scanning for missing downloads: \(error)")
            }
        }
        
        return restoredCount
    }
    
    private func getLocalUrlUnsafe(for urlString: String) -> URL? {
        let contentId = extractContentId(from: urlString)
        let registry = getRegistryUnsafe()
        
        for (downloadId, data) in registry {
            if let localUrlString = data["localUrl"] as? String,
               let localUrl = URL(string: localUrlString) {
                
                if downloadId == urlString ||
                   (!contentId.isEmpty && downloadId.contains(contentId)) ||
                   (!contentId.isEmpty && localUrlString.contains(contentId)) ||
                   urlString.contains(downloadId) {
                    return localUrl
                }
            }
        }
        
        return nil
    }
    
    private func extractDownloadIdFromFilename(_ filename: String) -> String? {
        let components = filename.replacingOccurrences(of: ".movpkg", with: "").split(separator: "_")
        if components.count >= 1 {
            let downloadId = String(components[0])
            if downloadId.count == 24 {
                return downloadId
            }
        }
        return nil
    }
    
    private func getRegistryUnsafe() -> [String: [String: Any]] {
        return userDefaults.dictionary(forKey: registryKey) as? [String: [String: Any]] ?? [:]
    }
    
    private func saveRegistryUnsafe(_ registry: [String: [String: Any]]) {
        userDefaults.set(registry, forKey: registryKey)
    }
    
    private func removeFromRegistryUnsafe(downloadId: String) {
        var registry = getRegistryUnsafe()
        registry.removeValue(forKey: downloadId)
        saveRegistryUnsafe(registry)
    }
    
    // MARK: - Helper Methods
    
    func getFileSize(at url: URL) -> Int64 {
        do {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return 0
            }
            
            if isDirectory.boolValue {
                return getFolderSize(url)
            } else {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                return attributes[.size] as? Int64 ?? 0
            }
        } catch {
            return 0
        }
    }
    
    private func getFolderSize(_ folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return 0
        }
        
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if let isDirectory = resourceValues.isDirectory, !isDirectory {
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                }
            } catch {
                continue
            }
        }
        
        return totalSize
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func extractContentId(from url: String) -> String {
        let patterns = [
            "([a-f0-9]{24})",
            "([a-f0-9]{32})",
            "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(location: 0, length: url.utf16.count)
                if let match = regex.firstMatch(in: url, options: [], range: range) {
                    return String(url[Range(match.range, in: url)!])
                }
            }
        }
        
        return ""
    }
    
    private func createDownloadsDirectoryIfNeeded() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadsPath = documentsPath.appendingPathComponent("downloads")
        
        if !FileManager.default.fileExists(atPath: downloadsPath.path) {
            do {
                try FileManager.default.createDirectory(at: downloadsPath, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("Failed to create downloads directory: \(error)")
            }
        }
    }
    
    private func getDeviceStorageStats() -> (total: Double, free: Double) {
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let totalSpace = (systemAttributes[.systemSize] as? NSNumber)?.int64Value ?? 0
            let freeSpace = (systemAttributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            
            return (total: Double(totalSpace), free: Double(freeSpace))
        } catch {
            return (total: 0, free: 0)
        }
    }
}
