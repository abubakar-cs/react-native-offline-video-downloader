package com.offlinevideodownloader

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.CacheEvictor
import androidx.media3.datasource.cache.CacheSpan
import androidx.media3.datasource.cache.SimpleCache
import java.io.File
import kotlin.math.ln
import kotlin.math.pow

@UnstableApi
object VideoCache {
    private var instance: SimpleCache? = null
    private val lock = Any()
    private const val TAG = "VideoCache"

    private const val CACHE_SIZE = 15L * 1024 * 1024 * 1024 // 15 GB

    private const val DOWNLOADS_DIR_NAME = "downloads"

    data class StorageStats(
        val totalSize: Long,
        val maxSize: Long,
        val availableSpace: Long,
        val usedPercentage: Int,
        val path: String,
        val isProtected: Boolean
    )

    fun getInstance(context: Context): SimpleCache {
        synchronized(lock) {
            if (instance == null) {
                val downloadsDir = File(context.filesDir, DOWNLOADS_DIR_NAME)

                val cacheEvictor = PersistentCacheEvictor()
                val databaseProvider = StandaloneDatabaseProvider(context)

                // Ensure directory exists
                if (!downloadsDir.exists()) {
                    val created = downloadsDir.mkdirs()
                    Log.d(TAG, "📁 Downloads directory created: $created")
                }

                instance = SimpleCache(downloadsDir, cacheEvictor, databaseProvider)
            }
            return instance!!
        }
    }

    fun release() {
        synchronized(lock) {
            try {
                instance?.let { cache ->
                    cache.release()
                    instance = null
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error releasing VideoCache: ${e.message}", e)
            }
        }
    }

    fun isInitialized(): Boolean {
        synchronized(lock) {
            return instance != null
        }
    }

    // Get current cache usage
    fun getCacheSize(context: Context): Long {
        return try {
            getInstance(context).cacheSpace
        } catch (e: Exception) {
            Log.w(TAG, "Error getting cache size: ${e.message}")
            0L
        }
    }

    // Get available cache space
    fun getAvailableCacheSpace(context: Context): Long {
        return CACHE_SIZE - getCacheSize(context)
    }

    fun removeDownload(context: Context, downloadId: String) {
        try {
            val cache = getInstance(context)

            val cacheKeys = cache.keys.toList()
            var removedCount = 0
            val totalKeys = cacheKeys.size

            for (key in cacheKeys) {
                try {
                    if (isKeyRelatedToDownload(key, downloadId)) {
                        cache.removeResource(key)
                        removedCount++
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Could not remove cache key: $key - ${e.message}")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error removing download $downloadId: ${e.message}", e)
        }
    }

    fun isDownloadCached(context: Context, downloadId: String): Boolean {
        return try {
            val cache = getInstance(context)
            val cacheKeys = cache.keys.toList()

            val relatedKeys = cacheKeys.filter { key ->
                isKeyRelatedToDownload(key, downloadId)
            }

            val isCached = relatedKeys.isNotEmpty()
            isCached
        } catch (e: Exception) {
            false
        }
    }

    private fun isKeyRelatedToDownload(cacheKey: String, downloadId: String): Boolean {
        try {
            // Direct match
            if (cacheKey == downloadId) {
                return true
            }

            // Check if cache key contains the download ID
            if (cacheKey.contains(downloadId)) {
                return true
            }

            // Extract content ID from both and compare
            val keyContentId = extractContentId(cacheKey)
            val downloadContentId = extractContentId(downloadId)

            if (keyContentId.isNotEmpty() && downloadContentId.isNotEmpty() && keyContentId == downloadContentId) {
                return true
            }

            return false
        } catch (e: Exception) {
            Log.w(TAG, "Error checking key relation: ${e.message}")
            return false
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

    fun getAllCacheKeys(context: Context): List<String> {
        return try {
            getInstance(context).keys.toList()
        } catch (e: Exception) {
            Log.w(TAG, "Error getting cache keys: ${e.message}")
            emptyList()
        }
    }

    // Return downloads directory path
    fun getCacheDirectoryPath(context: Context): String {
        return File(context.filesDir, DOWNLOADS_DIR_NAME).absolutePath
    }

    // Downloads and cache are in same place
    fun getDownloadsDirectoryPath(context: Context): String {
        return getCacheDirectoryPath(context) // Same directory!
    }

    // Get storage statistics
    fun getStorageStats(context: Context): StorageStats {
        return try {
            val downloadsDir = File(context.filesDir, DOWNLOADS_DIR_NAME)
            val totalSize = if (downloadsDir.exists()) getFolderSize(downloadsDir) else 0L
            val availableSpace = CACHE_SIZE - totalSize
            val usedPercentage = (totalSize * 100 / CACHE_SIZE).toInt()

            StorageStats(
                totalSize = totalSize,
                maxSize = CACHE_SIZE,
                availableSpace = availableSpace,
                usedPercentage = usedPercentage,
                path = downloadsDir.absolutePath,
                isProtected = true
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error getting storage stats: ${e.message}")
            StorageStats(0, CACHE_SIZE, CACHE_SIZE, 0, "unknown", true)
        }
    }

    // Calculate folder size
    private fun getFolderSize(folder: File): Long {
        return try {
            if (!folder.exists()) return 0L

            var size = 0L
            folder.walkTopDown().forEach { file ->
                if (file.isFile) {
                    size += file.length()
                }
            }
            size
        } catch (e: Exception) {
            Log.w(TAG, "Error calculating folder size: ${e.message}")
            0L
        }
    }
}

@UnstableApi
class PersistentCacheEvictor : CacheEvictor {

    companion object {
        private const val TAG = "PersistentCacheEvictor"
    }

    override fun onCacheInitialized() {
        Log.d(TAG, "Cache initialized - persistent mode (no auto-deletion)")
    }

    override fun onStartFile(cache: androidx.media3.datasource.cache.Cache, key: String, position: Long, length: Long) {
        // Log.d(TAG, "Starting file: $key (${formatBytes(length)})")
    }

    override fun onSpanAdded(cache: androidx.media3.datasource.cache.Cache, span: CacheSpan) {
        // Log.d(TAG, "Content cached: ${span.key} (${formatBytes(span.length)})")
    }

    override fun onSpanRemoved(cache: androidx.media3.datasource.cache.Cache, span: CacheSpan) {
        // Log.d(TAG, "Content removed: ${span.key} (${formatBytes(span.length)})")
    }

    override fun onSpanTouched(cache: androidx.media3.datasource.cache.Cache, oldSpan: CacheSpan, newSpan: CacheSpan) {
        // Log.v(TAG, "Content accessed: ${newSpan.key}")
    }

    override fun requiresCacheSpanTouches(): Boolean {
        return false
    }

    // Helper method to format bytes
    @SuppressLint("DefaultLocale")
    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val k = 1024
        val sizes = arrayOf("B", "KB", "MB", "GB", "TB")
        val i = (ln(bytes.toDouble()) / ln(k.toDouble())).toInt()
        return String.format("%.1f %s", bytes / k.toDouble().pow(i.toDouble()), sizes[i])
    }
}
