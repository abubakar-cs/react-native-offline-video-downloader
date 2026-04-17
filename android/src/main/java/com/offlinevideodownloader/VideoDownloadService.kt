package com.offlinevideodownloader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.content.Context
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.media3.common.util.Log
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadCursor
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.offline.DownloadService
import androidx.media3.exoplayer.scheduler.PlatformScheduler
import androidx.media3.exoplayer.scheduler.Scheduler
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import kotlin.math.roundToInt
import org.json.JSONObject

@UnstableApi
class VideoDownloadService : DownloadService(
    /** Single slot: progress while downloading, then “Downloaded” (user-dismissible) on same id. */
    FOREGROUND_NOTIFICATION_ID,
    /* Extra delayed refresh only; Media3 still refreshes on each download event. */
    15_000L,
    CHANNEL_ID,
    R.string.download_channel_name,
    R.string.download_channel_description,
) {
    data class NotificationMeta(
        val batchId: String = "",
        val batchTotal: Int = 0,
        val showTitle: String = "",
        val episodeTitle: String = "",
        val posterUri: String = ""
    )

    data class BatchProgress(
        val batchId: String,
        val showTitle: String,
        val posterUri: String,
        val totalEpisodes: Int,
        val completedEpisodes: Int,
        val failedEpisodes: Int,
        val aggregateProgress: Int
    )

    companion object {
        private const val TAG = "VideoDownloadService"
        /** FGS + same id after stop so the tile persists as “Downloaded” until the user dismisses it. */
        private const val FOREGROUND_NOTIFICATION_ID = 1
        /** One slot for failed episode notifications (replaced if another fails). */
        private const val DOWNLOAD_FAILED_NOTIFICATION_ID = 57002
        /** One slot for user-paused / stopped mid-progress (replaced if another episode pauses). */
        private const val DOWNLOAD_PAUSED_NOTIFICATION_ID = 57003
        private const val FG_NOTIFICATION_MIN_REBUILD_INTERVAL_MS = 4_000L
        private const val AGGREGATE_QUANTUM_PERCENT = 5
        /** New id so devices pick up IMPORTANCE_DEFAULT (O+ won’t upgrade an old LOW channel). */
        private const val CHANNEL_ID = "scrolls_offline_show_downloads"
        private const val JOB_ID = 1001
        /** HTTP poster fetch must not run on the main thread (NetworkOnMainThreadException). */
        private val posterHttpExecutor = Executors.newSingleThreadExecutor()
        private const val POSTER_HTTP_TIMEOUT_MS = 12_000
        private const val NOTIFICATION_ICON_MAX_PX = 320
        private val posterBitmapCache = ConcurrentHashMap<String, Bitmap>()
        private const val POSTER_CACHE_MAX_ENTRIES = 8
        /** One async HTTP fetch per URL — avoids stacked futures and icon flicker. */
        private val httpPosterInflight =
            Collections.newSetFromMap(ConcurrentHashMap<String, Boolean>())
        /** FG may keep polling after a delete; only treat completion as "real" shortly after STATE_COMPLETED terminalizes the batch. */
        private const val RECENT_LEGIT_COMPLETE_MAX_MS = 180_000L
    }

    private var fgCachedNotification: Notification? = null
    private var fgCacheKey: String = ""
    private var fgCachedAtElapsed: Long = 0L

    /** When Media3 passes an empty list, keep batch UI until the index no longer contains the batch. */
    private var lastStableBatchProgress: BatchProgress? = null

    /**
     * Batch we actually reached 100% for in [getForegroundNotification]. Used in [onDestroy] to
     * re-post a dismissible completion tile after the FGS ends — without scanning the whole index
     * (which would mis-attribute an older completed show after the user deletes another).
     */
    private var pendingPostDestroyCompletion: BatchProgress? = null

    /**
     * Last batch that received [Download.STATE_COMPLETED] from Media3 (any episode).
     * Updated on every completed episode so [getForegroundNotification] can show the batch
     * terminal state even if it runs before/without a separate terminalizing callback ordering.
     */
    private var recentlyLegitCompletedBatchId: String? = null
    private var recentlyLegitCompletedAt: Long = 0L

    /** Batch id we last showed as in-progress in FG (not yet 100%); bridges FG/listener race on final tick. */
    private var lastBatchIdActivelyDownloading: String? = null

    /**
     * Last large icon we actually showed for this poster URL. HTTP loads are async; reusing avoids
     * large-icon flicker between ticks.
     */
    private var stickyPosterUri: String = ""
    private var stickyPosterBitmap: Bitmap? = null

    private fun clearStickyPoster() {
        stickyPosterUri = ""
        stickyPosterBitmap = null
    }

    /**
     * Opens the host app with `chaishots://offline-play?showId=…` so JS can navigate to offline playback.
     * [batchId] is the show id passed from JS as `batchId` in download options.
     */
    private fun pendingIntentOpenOfflineShow(showId: String): PendingIntent? {
        if (showId.isBlank()) return null
        val ctx = applicationContext
        val pkg = ctx.packageName
        val base = ctx.packageManager.getLaunchIntentForPackage(pkg) ?: return null
        val uri =
            Uri.parse("chaishots://offline-play")
                .buildUpon()
                .appendQueryParameter("showId", showId)
                .build()
        val launch =
            Intent(base).apply {
                action = Intent.ACTION_VIEW
                data = uri
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
            }
        val reqCode = (0x52000 + showId.hashCode()) and 0xffff
        return PendingIntent.getActivity(
            ctx,
            reqCode,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun invalidateForegroundNotificationCache() {
        fgCachedNotification = null
        fgCacheKey = ""
        fgCachedAtElapsed = 0L
    }

    private fun fgCacheKeyDownloading(bp: BatchProgress): String {
        val q =
            (bp.aggregateProgress.coerceIn(0, 100) / AGGREGATE_QUANTUM_PERCENT) * AGGREGATE_QUANTUM_PERCENT
        return "d|${bp.batchId}|${bp.completedEpisodes}|${bp.totalEpisodes}|$q"
    }

    private fun fgCacheKeyComplete(bp: BatchProgress): String =
        "c|${bp.batchId}|${bp.totalEpisodes}|${bp.completedEpisodes}"

    private fun foregroundNotificationCached(key: String, build: () -> Notification): Notification {
        val now = SystemClock.elapsedRealtime()
        val cached = fgCachedNotification
        if (cached != null &&
            key == fgCacheKey &&
            now - fgCachedAtElapsed < FG_NOTIFICATION_MIN_REBUILD_INTERVAL_MS
        ) {
            return cached
        }
        val n = build()
        fgCacheKey = key
        fgCachedAtElapsed = now
        fgCachedNotification = n
        return n
    }

    private val terminalNotificationListener =
        object : DownloadManager.Listener {
            override fun onDownloadChanged(
                manager: DownloadManager,
                download: Download,
                finalException: Exception?,
            ) {
                when (download.state) {
                    Download.STATE_COMPLETED -> {
                        try {
                            val meta = parseNotificationMeta(download) ?: return
                            val bid = meta.batchId
                            if (bid.isBlank()) return
                            // Any episode completion for this batch — not only the terminal row — so FG
                            // polls that already see 100% still match within RECENT_LEGIT_COMPLETE_MAX_MS.
                            recentlyLegitCompletedBatchId = bid
                            recentlyLegitCompletedAt = SystemClock.elapsedRealtime()
                        } catch (e: Exception) {
                            Log.w(TAG, "recentlyLegitCompleted: ${e.message}")
                        }
                    }
                    Download.STATE_FAILED -> {
                        try {
                            notifyDownloadFailed(download, finalException)
                        } catch (e: Exception) {
                            Log.w(TAG, "notifyDownloadFailed: ${e.message}")
                        }
                    }
                    Download.STATE_STOPPED -> {
                        // User pause / stop mid-save — skip never-started (0%) and finished (100%) rows.
                        val pct =
                            if (download.percentDownloaded.isNaN() || download.percentDownloaded < 0f) {
                                0f
                            } else {
                                download.percentDownloaded
                            }
                        if (pct <= 0f || pct >= 99.5f) return
                        try {
                            notifyDownloadPaused(download)
                        } catch (e: Exception) {
                            Log.w(TAG, "notifyDownloadPaused: ${e.message}")
                        }
                    }
                    else -> Unit
                }
            }

            override fun onDownloadRemoved(
                manager: DownloadManager,
                download: Download,
            ) {
                // User deleted a show (or any row removed) — do not let the next FG poll resurrect
                // "Downloaded" for some other fully-complete batch still in the index.
                recentlyLegitCompletedBatchId = null
                recentlyLegitCompletedAt = 0L
                pendingPostDestroyCompletion = null
                lastBatchIdActivelyDownloading = null
            }
        }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()

        if (!OfflineVideoDownloaderModule.isDownloadManagerInitialized()) {
            Log.w(TAG, "DownloadManager not initialized, initializing now...")
            try {
                OfflineVideoDownloaderModule.initializeDownloadManagerForService(applicationContext)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize DownloadManager in service", e)
            }
        }
        try {
            getDownloadManager().addListener(terminalNotificationListener)
        } catch (e: Exception) {
            Log.w(TAG, "addListener terminalNotificationListener: ${e.message}")
        }
    }

    override fun getDownloadManager(): DownloadManager {
        var manager = OfflineVideoDownloaderModule.getDownloadManager()

        if (manager == null) {
            Log.w(TAG, "DownloadManager was null, attempting initialization...")
            try {
                OfflineVideoDownloaderModule.initializeDownloadManagerForService(applicationContext)
                manager = OfflineVideoDownloaderModule.getDownloadManager()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize DownloadManager", e)
            }
        }

        return manager ?: throw IllegalStateException("DownloadManager could not be initialized")
    }

    override fun onDestroy() {
        try {
            getDownloadManager().removeListener(terminalNotificationListener)
        } catch (_: Exception) {
        }
        val pending = pendingPostDestroyCompletion
        pendingPostDestroyCompletion = null
        super.onDestroy()
        // Re-post completion only for the batch we *just* finished in this service instance, and
        // only if that batch is still in the index (skip if the user already removed those downloads).
        if (pending != null && downloadIndexContainsBatchId(pending.batchId)) {
            try {
                val nm =
                    applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(
                    FOREGROUND_NOTIFICATION_ID,
                    createBatchCompletedNotification(pending),
                )
            } catch (e: Exception) {
                Log.w(TAG, "Post-destroy completion notification: ${e.message}")
            }
        }
    }

    override fun getScheduler(): Scheduler? {
        return try {
            PlatformScheduler(this, JOB_ID)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create scheduler", e)
            null
        }
    }

    override fun getForegroundNotification(
        downloads: List<Download>,
        notMetRequirements: Int,
    ): Notification {
        var batchProgress = resolveCurrentBatchProgress(downloads)

        // Never fall back to a **fully completed** snapshot — that was the previous show’s tile and
        // masked the active download’s title / totals / poster for the next show.
        if (batchProgress == null && lastStableBatchProgress != null) {
            val stable = lastStableBatchProgress!!
            if (!isTerminalBatchSnapshot(stable)) {
                batchProgress = stable
            }
        }

        if (batchProgress == null && lastStableBatchProgress != null) {
            val sid = lastStableBatchProgress!!.batchId
            if (downloadIndexContainsBatchId(sid)) {
                batchProgress = resolveCurrentBatchProgress(emptyList())
                if (batchProgress == null) {
                    val stable = lastStableBatchProgress!!
                    if (!isTerminalBatchSnapshot(stable)) {
                        batchProgress = stable
                    }
                }
            }
        }

        if (batchProgress != null) {
            val prevBatchId = lastStableBatchProgress?.batchId
            if (prevBatchId != null && prevBatchId != batchProgress.batchId) {
                clearStickyPoster()
                invalidateForegroundNotificationCache()
                pendingPostDestroyCompletion = null
                lastBatchIdActivelyDownloading = null
            }
            lastStableBatchProgress = batchProgress

            val isComplete =
                batchProgress.totalEpisodes > 0 &&
                    batchProgress.completedEpisodes >= batchProgress.totalEpisodes

            if (!isComplete && batchProgress.batchId.isNotBlank()) {
                lastBatchIdActivelyDownloading = batchProgress.batchId
            }

            if (isComplete) {
                val done =
                    batchProgress.copy(
                        aggregateProgress = 100,
                        completedEpisodes = batchProgress.totalEpisodes,
                    )
                val now = SystemClock.elapsedRealtime()
                var legit =
                    batchProgress.batchId.isNotBlank() &&
                        batchProgress.batchId == recentlyLegitCompletedBatchId &&
                        (now - recentlyLegitCompletedAt) < RECENT_LEGIT_COMPLETE_MAX_MS
                // FG can observe 100% before the listener runs; same batch we were showing in progress.
                if (!legit &&
                    batchProgress.batchId.isNotBlank() &&
                    batchProgress.batchId == lastBatchIdActivelyDownloading
                ) {
                    legit = true
                    recentlyLegitCompletedBatchId = batchProgress.batchId
                    recentlyLegitCompletedAt = now
                }

                if (!legit) {
                    // Fully-complete row still in index (e.g. another show) after a delete — not a fresh finish.
                    lastStableBatchProgress = null
                    pendingPostDestroyCompletion = null
                    lastBatchIdActivelyDownloading = null
                    clearStickyPoster()
                    invalidateForegroundNotificationCache()
                    return foregroundNotificationCached("g|idle|${batchProgress.batchId}") {
                        createIdleDownloadsNotification()
                    }
                }

                pendingPostDestroyCompletion = done
                lastBatchIdActivelyDownloading = null
                // Drop completed batch from sticky FG state so the next download doesn’t inherit
                // this show’s title, episode count, or poster on the following notification ticks.
                lastStableBatchProgress = null
                clearStickyPoster()
                invalidateForegroundNotificationCache()
                // Completed: new fingerprint → immediate rebuild; then stays stable on cache.
                return foregroundNotificationCached(fgCacheKeyComplete(done)) {
                    createBatchCompletedNotification(done)
                }
            }

            lastStableBatchProgress = batchProgress
            return foregroundNotificationCached(fgCacheKeyDownloading(batchProgress)) {
                createBatchDownloadingNotification(batchProgress)
            }
        }

        lastStableBatchProgress = null
        clearStickyPoster()
        invalidateForegroundNotificationCache()

        return foregroundNotificationCached("g|preparing") {
            createMinimalOngoingNotification(
                "Downloading",
                "Preparing offline save…",
            )
        }
    }

    private fun createMinimalOngoingNotification(title: String, text: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setProgress(0, 0, false)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setAutoCancel(false)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    /** Neutral FG tile when we must not show another show’s “Downloaded” from the index only. */
    private fun createIdleDownloadsNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Downloads")
            .setContentText(" ")
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setProgress(0, 0, false)
            .setOngoing(true)
            .setSilent(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun createBatchDownloadingNotification(bp: BatchProgress): Notification {
        val title = if (bp.showTitle.isNotBlank()) bp.showTitle else "Downloading"
        val text = "${bp.completedEpisodes}/${bp.totalEpisodes} episodes · ${bp.aggregateProgress}%"
        val builder =
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setProgress(100, bp.aggregateProgress.coerceIn(0, 100), false)
                .setOngoing(true)
                .setAutoCancel(false)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        notificationLargeIcon(bp.posterUri)?.let { builder.setLargeIcon(it) }
        pendingIntentOpenOfflineShow(bp.batchId)?.let { builder.setContentIntent(it) }
        return builder.build()
    }

    private fun notifyDownloadFailed(download: Download, cause: Exception?) {
        val meta = parseNotificationMeta(download)
        val title =
            meta?.showTitle?.takeIf { it.isNotBlank() } ?: "Offline download"
        val episode = meta?.episodeTitle?.takeIf { it.isNotBlank() }
        val reason =
            cause?.message?.takeIf { it.isNotBlank() }
                ?: "Could not save this episode for offline playback."
        val shortText =
            if (episode != null) {
                "$episode — $reason"
            } else {
                reason
            }
        val bigText =
            buildString {
                if (episode != null) {
                    append(episode)
                    append("\n\n")
                }
                append(reason)
            }
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder =
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(shortText)
                .setStyle(
                    NotificationCompat.BigTextStyle()
                        .setBigContentTitle(title)
                        .bigText(bigText),
                )
                .setSmallIcon(android.R.drawable.stat_sys_warning)
                .setProgress(0, 0, false)
                .setOngoing(false)
                .setAutoCancel(true)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setCategory(NotificationCompat.CATEGORY_ERROR)
        notificationLargeIcon(meta?.posterUri)?.let { builder.setLargeIcon(it) }
        val bid = meta?.batchId?.takeIf { it.isNotBlank() } ?: ""
        pendingIntentOpenOfflineShow(bid)?.let { builder.setContentIntent(it) }
        nm.notify(DOWNLOAD_FAILED_NOTIFICATION_ID, builder.build())
    }

    private fun notifyDownloadPaused(download: Download) {
        val meta = parseNotificationMeta(download)
        val title =
            meta?.showTitle?.takeIf { it.isNotBlank() } ?: "Offline download"
        val episode = meta?.episodeTitle?.takeIf { it.isNotBlank() }
        val pct =
            if (download.percentDownloaded.isNaN() || download.percentDownloaded < 0f) {
                0
            } else {
                download.percentDownloaded.toInt().coerceIn(0, 100)
            }
        val shortText =
            if (episode != null) {
                "$episode — Paused at $pct%"
            } else {
                "Paused at $pct%"
            }
        val bigText =
            buildString {
                append("Download paused. Open the app to resume when you are ready.")
                append("\n\n")
                append(shortText)
            }
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder =
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(shortText)
                .setStyle(
                    NotificationCompat.BigTextStyle()
                        .setBigContentTitle(title)
                        .bigText(bigText),
                )
                .setSmallIcon(android.R.drawable.ic_media_pause)
                .setProgress(100, pct, false)
                .setOngoing(false)
                .setAutoCancel(true)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
        notificationLargeIcon(meta?.posterUri)?.let { builder.setLargeIcon(it) }
        val bidPaused = meta?.batchId?.takeIf { it.isNotBlank() } ?: ""
        pendingIntentOpenOfflineShow(bidPaused)?.let { builder.setContentIntent(it) }
        nm.notify(DOWNLOAD_PAUSED_NOTIFICATION_ID, builder.build())
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Show downloads",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Offline download progress and completion for each show"
                setSound(null, null)
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }

            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    /**
     * Entire show saved: same notification id as progress; not ongoing so the user can dismiss it.
     * [setAutoCancel] false — only explicit dismiss clears it (no tap-to-clear unless you add a content intent).
     */
    private fun createBatchCompletedNotification(bp: BatchProgress): Notification {
        val title = if (bp.showTitle.isNotBlank()) bp.showTitle else "Downloads"
        val shortText = "✓ Downloaded"
        val longText =
            "All ${bp.completedEpisodes}/${bp.totalEpisodes} episodes saved for offline playback."
        val builder =
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(shortText)
                .setStyle(
                    NotificationCompat.BigTextStyle()
                        .setBigContentTitle(title)
                        .bigText(longText),
                )
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setProgress(0, 0, false)
                .setOngoing(false)
                .setAutoCancel(false)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
        notificationLargeIcon(bp.posterUri)?.let { builder.setLargeIcon(it) }
        pendingIntentOpenOfflineShow(bp.batchId)?.let { builder.setContentIntent(it) }
        return builder.build()
    }

    private fun downloadIndexContainsBatchId(batchId: String): Boolean {
        if (batchId.isBlank()) return false
        return try {
            getDownloadManager().downloadIndex.getDownloads().use { c ->
                while (c.moveToNext()) {
                    val m = parseNotificationMeta(c.download) ?: continue
                    if (m.batchId == batchId) return true
                }
                false
            }
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Pick notification seed meta for the **current** work unit. The download index often lists
     * older/completed shows first; using the first match caused the FG notification to keep showing
     * the first show’s title, episode count, and poster after another show finished downloading.
     */
    private fun findSeededNotificationMeta(downloads: List<Download>): NotificationMeta? {
        val hotStates =
            setOf(
                Download.STATE_QUEUED,
                Download.STATE_DOWNLOADING,
                Download.STATE_RESTARTING,
            )

        fun firstMetaWithBatch(list: Iterable<Download>): NotificationMeta? {
            for (d in list) {
                if (d.state !in hotStates) continue
                val meta = parseNotificationMeta(d) ?: continue
                if (meta.batchId.isNotBlank() && meta.batchTotal > 0) return meta
            }
            for (d in list) {
                if (d.state != Download.STATE_STOPPED) continue
                val meta = parseNotificationMeta(d) ?: continue
                if (meta.batchId.isNotBlank() && meta.batchTotal > 0) return meta
            }
            for (d in list) {
                val meta = parseNotificationMeta(d) ?: continue
                if (meta.batchId.isNotBlank() && meta.batchTotal > 0) return meta
            }
            return null
        }

        firstMetaWithBatch(downloads)?.let { return it }

        return try {
            val all = ArrayList<Download>()
            getDownloadManager().downloadIndex.getDownloads().use { c ->
                while (c.moveToNext()) {
                    all.add(c.download)
                }
            }
            // Prefer newer index rows first so an in-flight show wins over an older completed row.
            firstMetaWithBatch(all.asReversed())
        } catch (e: Exception) {
            Log.w(TAG, "findSeededNotificationMeta: ${e.message}")
            null
        }
    }

    private fun isTerminalBatchSnapshot(bp: BatchProgress): Boolean =
        bp.totalEpisodes > 0 && bp.completedEpisodes >= bp.totalEpisodes

    /** Same aggregation as [resolveCurrentBatchProgress] but pinned to one [batchId] (any index row). */
    private fun resolveBatchProgressForBatchId(batchId: String): BatchProgress? {
        if (batchId.isBlank()) return null
        var seededMeta: NotificationMeta? = null
        try {
            getDownloadManager().downloadIndex.getDownloads().use { c ->
                while (c.moveToNext()) {
                    val m = parseNotificationMeta(c.download) ?: continue
                    if (m.batchId == batchId && m.batchTotal > 0) {
                        seededMeta = m
                        break
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "resolveBatchProgressForBatchId seed: ${e.message}")
            return null
        }
        val sm = seededMeta ?: return null

        val currentBatchId = sm.batchId
        val currentBatchTotal = sm.batchTotal

        val manager = getDownloadManager()
        var completed = 0
        var failed = 0
        var progressAccumulator = 0f
        var maxShowTitle = sm.showTitle
        var maxPosterUri = sm.posterUri
        var matched = 0

        try {
            val cursor: DownloadCursor = manager.downloadIndex.getDownloads()
            cursor.use {
                while (it.moveToNext()) {
                    val d = it.download
                    val meta = parseNotificationMeta(d) ?: continue
                    if (meta.batchId != currentBatchId) continue
                    matched += 1

                    if (maxShowTitle.isBlank() && meta.showTitle.isNotBlank()) {
                        maxShowTitle = meta.showTitle
                    }
                    if (maxPosterUri.isBlank() && meta.posterUri.isNotBlank()) {
                        maxPosterUri = meta.posterUri
                    }

                    when (d.state) {
                        Download.STATE_COMPLETED -> {
                            completed += 1
                            progressAccumulator += 100f
                        }
                        Download.STATE_FAILED -> {
                            failed += 1
                            progressAccumulator += 0f
                        }
                        Download.STATE_DOWNLOADING,
                        Download.STATE_QUEUED,
                        Download.STATE_RESTARTING,
                        Download.STATE_STOPPED -> {
                            val pct =
                                if (d.percentDownloaded.isNaN() || d.percentDownloaded < 0f) {
                                    0f
                                } else {
                                    d.percentDownloaded
                                }
                            progressAccumulator += pct.coerceIn(0f, 100f)
                        }
                        else -> Unit
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "resolveBatchProgressForBatchId: ${e.message}")
            return null
        }

        val denominator = currentBatchTotal.coerceAtLeast(matched).coerceAtLeast(1)
        val aggregate = (progressAccumulator / denominator).roundToInt().coerceIn(0, 100)

        return BatchProgress(
            batchId = currentBatchId,
            showTitle = maxShowTitle,
            posterUri = maxPosterUri,
            totalEpisodes = denominator,
            completedEpisodes = completed.coerceAtMost(denominator),
            failedEpisodes = failed,
            aggregateProgress = aggregate,
        )
    }

    private fun resolveCurrentBatchProgress(downloads: List<Download>): BatchProgress? {
        val seededMeta = findSeededNotificationMeta(downloads) ?: return null

        val currentBatchId = seededMeta.batchId
        val currentBatchTotal = seededMeta.batchTotal

        val manager = getDownloadManager()
        var completed = 0
        var failed = 0
        var progressAccumulator = 0f
        var maxShowTitle = seededMeta.showTitle
        var maxPosterUri = seededMeta.posterUri
        var matched = 0

        try {
            val cursor: DownloadCursor = manager.downloadIndex.getDownloads()
            cursor.use {
                while (it.moveToNext()) {
                    val d = it.download
                    val meta = parseNotificationMeta(d) ?: continue
                    if (meta.batchId != currentBatchId) continue
                    matched += 1

                    if (maxShowTitle.isBlank() && meta.showTitle.isNotBlank()) {
                        maxShowTitle = meta.showTitle
                    }
                    if (maxPosterUri.isBlank() && meta.posterUri.isNotBlank()) {
                        maxPosterUri = meta.posterUri
                    }

                    when (d.state) {
                        Download.STATE_COMPLETED -> {
                            completed += 1
                            progressAccumulator += 100f
                        }
                        Download.STATE_FAILED -> {
                            failed += 1
                            progressAccumulator += 0f
                        }
                        Download.STATE_DOWNLOADING,
                        Download.STATE_QUEUED,
                        Download.STATE_RESTARTING,
                        Download.STATE_STOPPED -> {
                            val pct = if (d.percentDownloaded.isNaN() || d.percentDownloaded < 0f) 0f else d.percentDownloaded
                            progressAccumulator += pct.coerceIn(0f, 100f)
                        }
                        else -> Unit
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Batch progress query failed: ${e.message}")
            return null
        }

        val denominator = currentBatchTotal.coerceAtLeast(matched).coerceAtLeast(1)
        val aggregate = (progressAccumulator / denominator).roundToInt().coerceIn(0, 100)

        return BatchProgress(
            batchId = currentBatchId,
            showTitle = maxShowTitle,
            posterUri = maxPosterUri,
            totalEpisodes = denominator,
            completedEpisodes = completed.coerceAtMost(denominator),
            failedEpisodes = failed,
            aggregateProgress = aggregate
        )
    }

    private fun parseNotificationMeta(download: Download): NotificationMeta? {
        val raw = download.request.data
        if (raw == null || raw.isEmpty()) return null
        return try {
            val obj = JSONObject(String(raw, StandardCharsets.UTF_8))
            NotificationMeta(
                batchId = obj.optString("batchId", ""),
                batchTotal = obj.optInt("batchTotal", 0),
                showTitle = obj.optString("showTitle", ""),
                episodeTitle = obj.optString("episodeTitle", ""),
                posterUri = obj.optString("posterUri", "")
            )
        } catch (e: Exception) {
            Log.w(TAG, "parseNotificationMeta failed: ${e.message}")
            null
        }
    }

    private fun addPosterToCache(uri: String, decoded: Bitmap) {
        if (decoded.isRecycled) return
        while (posterBitmapCache.size >= POSTER_CACHE_MAX_ENTRIES) {
            val drop = posterBitmapCache.keys.firstOrNull() ?: break
            posterBitmapCache.remove(drop)
        }
        posterBitmapCache[uri] = decoded
    }

    private fun scheduleHttpPosterPrefetch(url: String) {
        if (posterBitmapCache.containsKey(url)) return
        if (!httpPosterInflight.add(url)) return
        posterHttpExecutor.execute {
            try {
                val bmp = downloadPosterFromHttp(url) ?: return@execute
                addPosterToCache(url, bmp)
            } catch (e: Exception) {
                Log.w(TAG, "Poster HTTP async: ${e.message}")
            } finally {
                httpPosterInflight.remove(url)
            }
        }
    }

    /**
     * Large icon for notifications: never blocks on HTTP (that caused tray blinking when
     * timeouts/null alternated with decoded bitmaps). Local paths decode synchronously.
     */
    private fun notificationLargeIcon(posterUri: String?): Bitmap? {
        val value = posterUri?.trim().orEmpty()
        if (value.isBlank()) return null

        posterBitmapCache[value]?.let { cached ->
            if (!cached.isRecycled) {
                stickyPosterUri = value
                stickyPosterBitmap = cached
                return cached
            }
            posterBitmapCache.remove(value)
        }

        return when {
            value.startsWith("http://") || value.startsWith("https://") -> {
                scheduleHttpPosterPrefetch(value)
                if (value == stickyPosterUri &&
                    stickyPosterBitmap != null &&
                    !stickyPosterBitmap!!.isRecycled
                ) {
                    stickyPosterBitmap
                } else {
                    null
                }
            }
            else -> {
                val decoded =
                    try {
                        decodeLocalPosterBitmap(value)
                    } catch (e: Exception) {
                        Log.w(TAG, "Poster decode failed: ${e.message}")
                        null
                    }
                if (decoded != null) {
                    addPosterToCache(value, decoded)
                    stickyPosterUri = value
                    stickyPosterBitmap = decoded
                    decoded
                } else if (value == stickyPosterUri &&
                    stickyPosterBitmap != null &&
                    !stickyPosterBitmap!!.isRecycled
                ) {
                    stickyPosterBitmap
                } else {
                    null
                }
            }
        }
    }

    private fun decodeLocalPosterBitmap(value: String): Bitmap? {
        val path = when {
            value.startsWith("file://") -> value.removePrefix("file://")
            else -> value
        }
        val file = File(path)
        val absolute = if (file.exists()) file.absolutePath else path
        val raw = BitmapFactory.decodeFile(absolute) ?: return null
        return scaleBitmapForNotification(raw)
    }

    private fun downloadPosterFromHttp(url: String): Bitmap? {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = POSTER_HTTP_TIMEOUT_MS
            readTimeout = POSTER_HTTP_TIMEOUT_MS
            doInput = true
            instanceFollowRedirects = true
            setRequestProperty(
                "User-Agent",
                "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
            )
            setRequestProperty("Accept", "image/webp,image/apng,image/*,*/*;q=0.8")
        }
        connection.inputStream.use { input ->
            val raw = BitmapFactory.decodeStream(input) ?: return null
            return scaleBitmapForNotification(raw)
        }
    }

    private fun scaleBitmapForNotification(src: Bitmap): Bitmap {
        val maxDim = NOTIFICATION_ICON_MAX_PX
        val w = src.width
        val h = src.height
        if (w <= 0 || h <= 0) return src
        if (w <= maxDim && h <= maxDim) return src
        val ratio = minOf(maxDim.toFloat() / w, maxDim.toFloat() / h)
        val nw = (w * ratio).toInt().coerceAtLeast(1)
        val nh = (h * ratio).toInt().coerceAtLeast(1)
        return try {
            Bitmap.createScaledBitmap(src, nw, nh, true)
        } catch (e: Exception) {
            Log.w(TAG, "Poster scale: ${e.message}")
            src
        }
    }
}
