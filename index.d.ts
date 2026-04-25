declare module "react-native-offline-video-downloader" {
  export interface VideoTrack {
    height: number;
    width: number;
    bitrate: number;
    size: number;
    formattedSize: string;
    quality: string;
    trackId?: string;
    codecs?: string; // e.g., "avc1.640028" for H.264
    codecFamily?: "hevc" | "h264" | "other";
    streamType?: string; // "SEPARATE_AUDIO_VIDEO" or "MUXED"
  }

  export interface AudioTrack {
    language: string;
    label: string;
    channelCount: number; // Will always be <= 2 for stereo/mono
    audioType: "stereo" | "mono";
    bitrate: number;
    size: number; // Size in bytes
    formattedSize: string;
    mimeType?: string; // e.g., "audio/mp4a-latm" for AAC
  }

  export interface AvailableTracksResult {
    videoTracks: VideoTrack[];
    audioTracks: AudioTrack[];
    duration: number;
    streamType?: string; // "SEPARATE_AUDIO_VIDEO" or "MUXED"
    allowedQualities?: number[]; // e.g., [480, 720, 1080]
    availableQualityCount?: number;
    deviceHevcHardwareDecodeSupported?: boolean;
    devicePreferredDownloadCodec?: "hevc" | "h264";
  }

  export interface VideoCodecDownloadPreference {
    preferredCodec: "hevc" | "h264";
    hevcHardwareDecodeSupported: boolean;
    platform: "ios" | "android";
  }

  export interface DownloadOptions {
    headers?: Record<string, string>;
    /** Android: batch key shared by all episodes in a show download */
    batchId?: string;
    batchTotal?: number;
    showTitle?: string;
    episodeTitle?: string;
    posterUri?: string;
  }

  export type DownloadState =
    | "queued"
    | "downloading"
    | "completed"
    | "failed"
    | "removing"
    | "restarting"
    | "stopped"
    | "unknown";

  export interface DownloadProgressEvent {
    downloadId: string;
    progress: number;
    bytesDownloaded: number;
    totalBytes: number;
    state: DownloadState;
    formattedDownloaded: string;
    formattedTotal: string;
    isCompleted: boolean;
  }

  export interface DownloadStatus {
    downloadId: string;
    uri?: string;
    state: DownloadState;
    progress: number;
    bytesDownloaded: number;
    totalBytes: number;
    formattedDownloaded: string;
    formattedTotal: string;
    isCompleted: boolean;
  }

  export type PlaybackMode = "offline" | "online";

  export interface PlaybackModeResult {
    mode: PlaybackMode;
    status?: string;
  }

  export interface PlaybackModeInfo {
    currentMode: PlaybackMode;
    description: string;
    behavior: string;
  }
  export interface StorageInfo {
    currentCacheSizeMB: number;
    availableSpaceMB: number;
    totalCacheSizeMB: number;
    currentCacheFormatted: string;
    availableSpaceFormatted: string;
    hasEnoughSpace: boolean;
  }

  export interface DownloadCapabilityCheck {
    canDownload: boolean;
    availableSpaceMB: number;
    requiredSpaceMB: number;
    availableSpaceFormatted: string;
    requiredSpaceFormatted: string;
  }

  export interface SyncProgressResult {
    totalDownloads: number;
    activeDownloads: number;
    completedDownloads: number;
    incompleteDownloads: number;
    restoredDownloads: number;
    downloads: any[];
  }

  export interface RestartResult {
    success: boolean;
    downloadId: string;
    state: DownloadState;
    message: string;
  }

  export interface UseOfflineDownloaderReturn {
    state: DownloadStatus | null;
    progress: number;
    isLoading: boolean;
    error: string | null;
    bytesDownloaded: number;
    formattedBytes: string;
    offlineUri: string | null;
    storageInfo: StorageInfo | null;
    isDownloaded: boolean;
    isDownloading: boolean;
    isPaused: boolean;
    isFailed: boolean;
    downloadStream: (
      masterUrl: string,
      selectedHeight: number,
      selectedWidth?: number,
      options?: DownloadOptions
    ) => Promise<void>;
    pauseDownload: () => Promise<void>;
    resumeDownload: () => Promise<void>;
    cancelDownload: () => Promise<void>;
    checkStatus: () => Promise<void>;
    getOfflineUri: () => Promise<string | null>;
    checkStorage: () => Promise<void>;
  }

  export class OfflineDownloader {
    // Track information
    static getAvailableTracks(
      masterUrl: string,
      options?: DownloadOptions
    ): Promise<AvailableTracksResult>;
    static getVideoCodecDownloadPreference(): Promise<VideoCodecDownloadPreference>;
    // Storage management
    static checkStorageSpace(): Promise<StorageInfo>;
    static canDownloadContent(
      estimatedSizeBytes: number
    ): Promise<DownloadCapabilityCheck>;

    // Download management
    static downloadStream(
      masterUrl: string,
      downloadId: string,
      selectedHeight: number,
      selectedWidth?: number,
      options?: DownloadOptions
    ): Promise<{
      downloadId: string;
      state: string;
      dolbyAtmosPreferred?: boolean;
    }>;

    // Download control
    static pauseDownload(downloadId: string): Promise<boolean>;
    static resumeDownload(downloadId: string): Promise<boolean>;
    static cancelDownload(downloadId: string): Promise<boolean>;
    static deleteAllDownloads(
      onProgress?: (progress: {
        current: number;
        total: number;
        percentage: number;
        currentDownloadId: string;
      }) => void
    ): Promise<{
      success: boolean;
      deletedCount: number;
      failedCount: number;
      errors: Array<{ downloadId: string; error: string }>;
      message: string;
    }>;
    static syncDownloadProgress(): Promise<SyncProgressResult>;
    static restartIncompleteDownload(
      downloadId: string
    ): Promise<RestartResult>;
    static getIncompleteDownloads(): Promise<any[]>;
    static restoreDownloads(): Promise<{
      synced: SyncProgressResult;
      incomplete: any[];
      needsRestart: number;
    }>;
    static autoRestartIncompleteDownloads(): Promise<{
      attempted: number;
      succeeded: number;
      failed: number;
      results: RestartResult[];
    }>;

    // Status methods
    static isDownloaded(downloadId: string): Promise<boolean>;
    static getDownloadStatus(downloadId: string): Promise<DownloadStatus>;
    static getAllDownloads(): Promise<any[]>;
    static getOfflinePlaybackUri(downloadId: string): Promise<string | null>;

    // Playback mode control
    static setPlaybackMode(mode: PlaybackMode): Promise<PlaybackModeResult>;
    static getPlaybackMode(): Promise<PlaybackMode>;
    static setOfflineMode(): Promise<PlaybackModeResult>;
    static setOnlineMode(): Promise<PlaybackModeResult>;

    // Event listeners
    static onDownloadProgress(
      downloadId: string,
      callback: (progress: DownloadProgressEvent) => void
    ): () => void;
    static onAllDownloadEvents(
      callback: (progress: DownloadProgressEvent) => void
    ): () => void;
    static removeListenersForDownload(downloadId: string): void;
    static removeAllListeners(): void;

    // Utilities
    static formatBytes(bytes: number): string;
    static calculateProgressPercentage(current: number, total: number): number;
  }

  export default OfflineDownloader;
  export const eventEmitter: any;
}
