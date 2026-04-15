package com.offlinevideodownloader

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.common.util.Log
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadCursor
import java.lang.ref.WeakReference
import kotlin.math.ln
import kotlin.math.pow

@UnstableApi
class OfflineDataSourceProvider(private val context: Context) {

    companion object {
        private var instanceRef: WeakReference<OfflineDataSourceProvider>? = null
        private const val TAG = "OfflineDataSource"

        fun getInstance(context: Context): OfflineDataSourceProvider {
            instanceRef?.get()?.let { existingInstance ->
                return existingInstance
            }

            val newInstance = OfflineDataSourceProvider(context.applicationContext)
            instanceRef = WeakReference(newInstance)
            return newInstance
        }

        fun cleanup() {
            instanceRef?.clear()
            instanceRef = null
        }

        /**
         * Detects when the URL passed to the player refers to the same Media3 offline download
         * as [storedRequestUri] (Exo download request). Mux playback IDs are not 24-char hex,
         * so equality / legacy hex matching alone often misses and the player falls back to HTTP.
         */
        fun playbackUrisReferToSameOfflineAsset(storedRequestUri: String, playerUri: String): Boolean {
            val a = storedRequestUri.trim()
            val b = playerUri.trim()
            if (a == b) return true
            val baseA = stripQueryAndFragment(a).trimEnd('/')
            val baseB = stripQueryAndFragment(b).trimEnd('/')
            if (baseA == baseB) return true
            val muxA = muxStreamKeyFromUri(a)
            val muxB = muxStreamKeyFromUri(b)
            if (muxA.isNotEmpty() && muxA == muxB) return true
            val hexA = extractHexLikeId(a)
            val hexB = extractHexLikeId(b)
            return hexA.isNotEmpty() && hexA == hexB
        }

        private fun stripQueryAndFragment(s: String): String {
            val noFrag = s.substringBefore("#")
            return noFrag.substringBefore("?")
        }

        private fun muxStreamKeyFromUri(uriString: String): String {
            return try {
                val u = Uri.parse(uriString)
                val host = u.host?.lowercase() ?: return ""
                if (!host.contains("mux.com")) return ""
                val path = u.path?.trim('/') ?: return ""
                if (path.isEmpty()) return ""
                val firstSeg = path.substringBefore('/')
                firstSeg.removeSuffix(".m3u8").removeSuffix(".m3u")
            } catch (_: Exception) {
                ""
            }
        }

        private fun extractHexLikeId(url: String): String {
            Regex("([a-f0-9]{32})").find(url)?.value?.let { return it }
            return Regex("([a-f0-9]{24})").find(url)?.value ?: ""
        }
    }

    fun createCacheAwareDataSourceFactory(headers: Map<String, String>? = null): DataSource.Factory {
        val cache = VideoCache.getInstance(context)

        // Create HTTP data source factory
        val httpDataSourceFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(30000)
            .setReadTimeoutMs(30000)
            .setUserAgent("ExoPlayer-OfflineDownloader")

        headers?.let {
            httpDataSourceFactory.setDefaultRequestProperties(it.toMutableMap())
        }

        // Create default data source factory
        val upstreamFactory = DefaultDataSource.Factory(context, httpDataSourceFactory)

        return CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(upstreamFactory)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    }

    fun isContentCached(uri: String): Boolean {
        var downloadsCursor: DownloadCursor? = null
        return try {
            val downloadManager = OfflineVideoDownloaderModule.getDownloadManager()
            if (downloadManager == null) {
                return false
            }

            downloadsCursor = downloadManager.downloadIndex.getDownloads()

            var foundMatch = false
            var checkedCount = 0
            val maxChecks = 50
            val startTime = System.currentTimeMillis()
            val maxTime = 3000L

            try {
                while (downloadsCursor.moveToNext() && checkedCount < maxChecks &&
                    (System.currentTimeMillis() - startTime) < maxTime
                ) {
                    checkedCount++
                    try {
                        val download = downloadsCursor.download

                        if (download.state == Download.STATE_COMPLETED) {
                            val downloadUri = download.request.uri.toString()
                            if (OfflineDataSourceProvider.playbackUrisReferToSameOfflineAsset(
                                    downloadUri,
                                    uri,
                                )
                            ) {
                                foundMatch = true
                                break
                            }
                        }
                    } catch (e: Exception) {
                        continue
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Error iterating downloads: ${e.message}")
            }
            foundMatch
        } catch (e: Exception) {
            false
        }  finally {
            try {
                downloadsCursor?.close()
            } catch (e: Exception) {
                Log.w(TAG, "Warning: Error closing cursor: ${e.message}")
            }
        }
    }

    @SuppressLint("DefaultLocale")
    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val k = 1024
        val sizes = arrayOf("B", "KB", "MB", "GB", "TB")
        val i = (ln(bytes.toDouble()) / ln(k.toDouble())).toInt()
        return String.format("%.1f %s", bytes / k.toDouble().pow(i.toDouble()), sizes[i])
    }

    fun getCacheStats(): Map<String, Any> {
        return try {
            val cache = VideoCache.getInstance(context)
            mapOf(
                "cacheSize" to cache.cacheSpace,
                "isInitialized" to VideoCache.isInitialized(),
                "cacheDirectory" to VideoCache.getCacheDirectoryPath(context)
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error getting cache stats: ${e.message}")
            mapOf("error" to e.message.orEmpty())
        }
    }
}

