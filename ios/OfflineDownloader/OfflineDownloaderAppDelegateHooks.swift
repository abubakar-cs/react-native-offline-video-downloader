import Foundation

/// Bridges `application(_:handleEventsForBackgroundURLSession:completionHandler:)` from the host app
/// to `VideoDownloadManager` so background `URLSession` work can finish and the system completion handler runs.
@objc(OfflineDownloaderAppDelegateHooks)
public final class OfflineDownloaderAppDelegateHooks: NSObject {
    @objc public static func setBackgroundURLSessionCompletionHandler(_ handler: @escaping () -> Void) {
        VideoDownloadManager.setBackgroundCompletionHandler(handler)
    }
}
