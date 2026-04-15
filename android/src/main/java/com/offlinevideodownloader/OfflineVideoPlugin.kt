package com.offlinevideodownloader

import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.StreamKey
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MediaSource
import com.brentvatne.exoplayer.RNVExoplayerPlugin
import com.brentvatne.react.ReactNativeVideoManager
import androidx.media3.common.util.Log
import com.brentvatne.common.api.Source
import androidx.media3.exoplayer.offline.Download
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

enum class PlaybackMode {
    ONLINE,   // Default - never use cache, always stream online
    OFFLINE   // Only use cache if available, no network requests
}

@UnstableApi
class OfflineVideoPlugin : RNVExoplayerPlugin {

    companion object {
        private const val TAG = "OfflineVideoPlugin"
        private var instance: OfflineVideoPlugin? = null

        private var playbackMode = PlaybackMode.ONLINE

        private val cacheCheckExecutor = Executors.newFixedThreadPool(3)
        private val handler = Handler(Looper.getMainLooper())

        fun cleanup() {
            try {
                cacheCheckExecutor.shutdown()
                if (!cacheCheckExecutor.awaitTermination(2, TimeUnit.SECONDS)) {
                    cacheCheckExecutor.shutdownNow()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Warning: Error shutting down executor: ${e.message}")
            }
        }

        fun setPlaybackMode(mode: PlaybackMode) {
            val pluginInstance = getInstance()

            synchronized(this) {
                val oldMode = playbackMode
                playbackMode = mode

                try {
                    pluginInstance.contentDownloadCache.clear()
                } catch (e: Exception) {
                    Log.w(TAG, "Warning: Error clearing cache during mode change: ${e.message}")
                }
            }
        }

        fun getPlaybackMode(): PlaybackMode = playbackMode

        fun getInstance(): OfflineVideoPlugin {
            if (instance == null) {
                instance = OfflineVideoPlugin()
            }
            return instance!!
        }
    }

    private val contentDownloadCache = ConcurrentHashMap<String, Boolean>()
    private val cacheTimeout = 2000L
    private var lastCacheCleanup = 0L
    private val cacheCleanupInterval = 300000L

    init {
        try {
            ReactNativeVideoManager.getInstance().registerPlugin(this)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register plugin: ${e.message}")
        }
    }

    override fun onInstanceCreated(id: String, player: ExoPlayer) {
        OfflineVideoRegistry.registerPlayer(player)
    }

    override fun onInstanceRemoved(id: String, player: ExoPlayer) {
        OfflineVideoRegistry.unregisterPlayer(player)
    }

    fun removeDownloadFromCache(downloadId: String) {
        synchronized(this) {
            try {

                val keysToRemove = mutableListOf<String>()

                contentDownloadCache.keys.forEach { uri ->
                    if (isUriRelatedToDownload(uri, downloadId)) {
                        keysToRemove.add(uri)
                    }
                }

                keysToRemove.forEach { key ->
                    contentDownloadCache.remove(key)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Error removing download from plugin cache: ${e.message}")
            }
        }
    }

    private fun isUriRelatedToDownload(uri: String, downloadId: String): Boolean {
        return try {
            // Direct match
            if (uri == downloadId || uri.contains(downloadId)) {
                return true
            }

            // Extract content ID from both and compare
            val uriContentId = extractContentId(uri)
            val downloadContentId = extractContentId(downloadId)

            if (uriContentId.isNotEmpty() && downloadContentId.isNotEmpty() && uriContentId == downloadContentId) {
                return true
            }

            false
        } catch (e: Exception) {
            Log.w(TAG, "Error checking URI relation: ${e.message}")
            false
        }
    }

    private fun extractContentId(identifier: String): String {
        return try {
            val regex = Regex("([a-f0-9]{24})")
            val match = regex.find(identifier)
            val contentId = match?.value ?: ""
            contentId
        } catch (e: Exception) {
            ""
        }
    }

    override fun overrideMediaDataSourceFactory(
        source: Source,
        mediaDataSourceFactory: DataSource.Factory
    ): DataSource.Factory? {
        return try {
            val uri = source.uri?.toString()
            if (uri == null) {
                Log.d(TAG, "URI is null, no override needed")
                return null
            }

            when (playbackMode) {
                PlaybackMode.ONLINE -> {
                    return null
                }

                PlaybackMode.OFFLINE -> {
                    val isCached = isContentCached(uri)
                    if (isCached) {
                        val headers = extractHeadersFromSource(source)
                        return OfflineVideoRegistry.createCacheAwareDataSourceFactory(headers)
                    } else {
                        return null
                    }
                }
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun isContentCached(uri: String): Boolean {
        return try {
            // Check in-memory cache first
            contentDownloadCache[uri]?.let { return it }

            val startTime = System.currentTimeMillis()
            val isCached = checkCacheWithTimeout(uri)
            val duration = System.currentTimeMillis() - startTime


            // Cache result to avoid future checks
            contentDownloadCache[uri] = isCached
            isCached

        } catch (e: Exception) {
            false
        }
    }

    private fun checkCacheWithTimeout(uri: String): Boolean {
        return try {
            val context = OfflineVideoRegistry.getAppContext()
            if (context == null) {
                return false
            }

            if (!OfflineVideoRegistry.isInitialized()) {
                return false
            }

            val future = cacheCheckExecutor.submit<Boolean> {
                try {
                    OfflineDataSourceProvider.getInstance(context).isContentCached(uri)
                } catch (e: Exception) {
                    Log.w(TAG, "Cache check failed in executor: ${e.message}")
                    false
                }
            }

            future.get(1000L, TimeUnit.MILLISECONDS)

        } catch (e: TimeoutException) {
            false
        } catch (e: Exception) {
            false
        }
    }

    override fun overrideMediaItemBuilder(
        source: Source,
        mediaItemBuilder: MediaItem.Builder
    ): MediaItem.Builder? {
        return try {
            val uri = source.uri?.toString()
            if (uri == null) return null

            when (playbackMode) {
                PlaybackMode.ONLINE -> {
                    return null
                }

                PlaybackMode.OFFLINE -> {
                    // OFFLINE: Only override if content is cached
                    val isCached = isContentCached(uri)
                    if (isCached) {

                        val streamKeys = getStreamKeys(uri)
                        if (streamKeys.isNotEmpty()) {
                            mediaItemBuilder.setStreamKeys(streamKeys)
                        }
                        return mediaItemBuilder
                    } else {
                        return null
                    }
                }
            }
        } catch (e: Exception) {
            null
        }
    }

    override fun shouldDisableCache(source: Source): Boolean {
        return false
    }

    override fun overrideMediaSourceFactory(
        source: Source,
        mediaSourceFactory: MediaSource.Factory,
        mediaDataSourceFactory: DataSource.Factory
    ): MediaSource.Factory? {
        return null
    }

    fun isContentDownloaded(uri: String): Boolean {
        return try {
            // Periodic cache cleanup
            val currentTime = System.currentTimeMillis()
            if (currentTime - lastCacheCleanup > cacheCleanupInterval) {
                contentDownloadCache.clear()
                lastCacheCleanup = currentTime
            }

            // Check cache first
            contentDownloadCache[uri]?.let {
                return it
            }

            val isDownloaded = OfflineVideoRegistry.getAppContext()?.let { context ->
                OfflineDataSourceProvider.getInstance(context).isContentCached(uri)
            } ?: false

            contentDownloadCache[uri] = isDownloaded

            isDownloaded
        } catch (e: Exception) {
            false
        }
    }

    private fun extractHeadersFromSource(source: Source): Map<String, String>? {
        return try {
            val headersMap = mutableMapOf<String, String>()

            try {
                val headersField = source.javaClass.getDeclaredField("headers")
                if (headersField != null) {
                    headersField.isAccessible = true
                    @Suppress("UNCHECKED_CAST")
                    val headers = headersField.get(source) as? Map<String, String>
                    headers?.let {
                        if (it.isNotEmpty()) {
                            headersMap.putAll(it)
                        }
                    }
                }
            } catch (e: NoSuchFieldException) {
                Log.d(TAG, "Headers field not found in source (normal for some sources)")
            } catch (e: SecurityException) {
                Log.d(TAG, "Security exception accessing headers (normal)")
            } catch (e: IllegalAccessException) {
                Log.d(TAG, "Cannot access headers field (normal)")
            } catch (e: ClassCastException) {
                Log.d(TAG, "Headers field is not Map<String, String> type")
            }

            headersMap.ifEmpty { null }
        } catch (e: Exception) {
            Log.w(TAG, "Unexpected error extracting headers: ${e.message}")
            null
        }
    }

    private fun getStreamKeys(uri: String): List<StreamKey> {
        return try {
            val context = OfflineVideoRegistry.getAppContext() ?: return emptyList()
            val downloadManager = OfflineVideoDownloaderModule.getDownloadManager() ?: return emptyList()

            val future = cacheCheckExecutor.submit<List<StreamKey>> {
                val downloadsCursor = downloadManager.downloadIndex.getDownloads()
                var streamKeys = emptyList<StreamKey>()

                try {
                    while (downloadsCursor.moveToNext()) {
                        val download = downloadsCursor.download
                        val requestUri = download.request.uri.toString()
                        if (download.state == Download.STATE_COMPLETED &&
                            OfflineDataSourceProvider.playbackUrisReferToSameOfflineAsset(
                                requestUri,
                                uri,
                            )
                        ) {
                            streamKeys = download.request.streamKeys
                            break
                        }
                    }
                } finally {
                    downloadsCursor.close()
                }

                streamKeys
            }

            future.get(500L, TimeUnit.MILLISECONDS)

        } catch (e: TimeoutException) {
            emptyList()
        } catch (e: Exception) {
            emptyList()
        }
    }
}
