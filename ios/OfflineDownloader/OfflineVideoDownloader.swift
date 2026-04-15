import Foundation
import AVFoundation
import React

@objc(OfflineVideoDownloader)
class OfflineVideoDownloader: RCTEventEmitter {
    
    private var videoDownloadManager: VideoDownloadManager!
    
    private static weak var sharedInstance: OfflineVideoDownloader?
        
    override init() {
        super.init()
        
        if let existingManager = VideoDownloadManager.getSharedInstance() {
            videoDownloadManager = existingManager
            videoDownloadManager.eventEmitter = self
        } else {
            videoDownloadManager = VideoDownloadManager()
            videoDownloadManager.eventEmitter = self
            VideoDownloadManager.setSharedInstance(videoDownloadManager)
        }
        
        OfflineVideoDownloader.sharedInstance = self
    }
    
    @objc static func getDownloadManagerInstance() -> VideoDownloadManager? {
        return sharedInstance?.videoDownloadManager
    }
    
    override func supportedEvents() -> [String]! {
        return [
            "DownloadProgress",
            "DownloadError"
        ]
    }
    
    override static func requiresMainQueueSetup() -> Bool {
        return true
    }
    
    // MARK: - React Native Bridge Methods
    
    @objc(getAvailableTracks:options:resolver:rejecter:)
    func getAvailableTracks(
        _ masterUrl: String,
        options: NSDictionary?,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.getAvailableTracks(
            masterUrl: masterUrl,
            options: options,
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(downloadStream:downloadId:selectedHeight:selectedWidth:options:resolver:rejecter:)
    func downloadStream(
        _ masterUrl: String,
        downloadId: String,
        selectedHeight: NSNumber,
        selectedWidth: NSNumber,
        options: NSDictionary?,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.downloadStream(
            masterUrl: masterUrl,
            downloadId: downloadId,
            selectedHeight: selectedHeight.intValue,
            selectedWidth: selectedWidth.intValue,
            options: options,
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(cancelDownload:resolver:rejecter:)
    func cancelDownload(
        _ downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.cancelDownload(
            downloadId: downloadId,
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(pauseDownload:resolver:rejecter:)
    func pauseDownload(
        _ downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.pauseDownload(
            downloadId: downloadId,
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(resumeDownload:resolver:rejecter:)
    func resumeDownload(
        _ downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.resumeDownload(
            downloadId: downloadId,
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(restartIncompleteDownload:resolver:rejecter:)
    func restartIncompleteDownload(
        _ downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.restartIncompleteDownload(
            downloadId: downloadId,
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(getAllDownloads:rejecter:)
    func getAllDownloads(
        _ resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.getAllDownloads(
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(getStorageInfo:rejecter:)
    func getStorageInfo(
        _ resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.getStorageInfo(
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(syncDownloadProgress:rejecter:)
    func syncDownloadProgress(
        _ resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.syncDownloadProgress(
            resolver: resolver,
            rejecter: rejecter
        )
    }

    @objc(testOfflinePlayback:resolver:rejecter:)
    func testOfflinePlayback(
        _ playbackUrl: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.testOfflinePlayback(
            playbackUrl: playbackUrl,
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(getDownloadState:resolver:rejecter:)
    func getDownloadState(
        _ downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.getDownloadState(
            downloadId: downloadId,
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(getOfflinePlaybackUri:resolver:rejecter:)
    func getOfflinePlaybackUri(
        _ downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.getOfflinePlaybackUri(
            downloadId: downloadId,
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(isDownloaded:resolver:rejecter:)
    func isDownloaded(
        _ downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.isDownloaded(
            downloadId: downloadId,
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(getDownloadStatus:resolver:rejecter:)
    func getDownloadStatus(
        _ downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.getDownloadStatus(
            downloadId: downloadId,
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(checkStorageSpace:rejecter:)
    func checkStorageSpace(
        _ resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.checkStorageSpace(
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(canDownloadContent:resolver:rejecter:)
    func canDownloadContent(
        _ estimatedSizeBytes: NSNumber,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.canDownloadContent(
            estimatedSizeBytes: estimatedSizeBytes.int64Value,
            resolver: resolver,
            rejecter: rejecter
        )
    }
    
    @objc(isDownloadCached:resolver:rejecter:)
    func isDownloadCached(
        _ downloadId: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.isDownloadCached(
            downloadId: downloadId,
            resolver: resolver,
            rejecter: rejecter
        )
    }

    @objc(setPlaybackMode:resolver:rejecter:)
    func setPlaybackMode(
        _ mode: String,
        resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.setPlaybackMode(
            mode: mode,
            resolver: resolver,
            rejecter: rejecter
        )
    }

    @objc(getPlaybackMode:rejecter:)
    func getPlaybackMode(
        _ resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.getPlaybackMode(
            resolver: resolver,
            rejecter: rejecter
        )
    }

    @objc(getVideoCodecDownloadPreference:rejecter:)
    func getVideoCodecDownloadPreference(
        _ resolver: @escaping RCTPromiseResolveBlock,
        rejecter: @escaping RCTPromiseRejectBlock
    ) {
        videoDownloadManager.getVideoCodecDownloadPreference(
            resolver: resolver,
            rejecter: rejecter
        )
    }
}
