import AVFoundation
import Foundation
import VideoToolbox

class VideoQualityManager {
    
    /// `true` when this device can hardware-decode HEVC (aligns with choosing an HEVC download renditions).
    static func isHevcHardwareDecodeSupported() -> Bool {
        if #available(iOS 11.0, *) {
            return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        }
        return false
    }
    
    func isHevcVariant(_ variant: AVAssetVariant) -> Bool {
        guard let videoAttributes = variant.videoAttributes else { return false }
        return videoAttributes.codecTypes.contains { $0 == kCMVideoCodecType_HEVC }
    }
    
    func isH264Variant(_ variant: AVAssetVariant) -> Bool {
        guard let videoAttributes = variant.videoAttributes else { return false }
        return videoAttributes.codecTypes.contains { $0 == kCMVideoCodecType_H264 }
    }
    
    func analyzeQualities(for asset: AVURLAsset) -> [[String: Any]] {
        var qualities: [[String: Any]] = []
        
        for variant in asset.variants {
            guard let videoAttributes = variant.videoAttributes else { continue }
            
            if isDolbyVisionVariant(variant) {
                continue
            }
            
            let height = Int(videoAttributes.presentationSize.height)
            let width = Int(videoAttributes.presentationSize.width)
            
            let peakBitRate = variant.peakBitRate ?? 0
            let averageBitRate = variant.averageBitRate ?? 0
            let bitrate = Int(averageBitRate > 0 ? averageBitRate : peakBitRate)
            
            guard bitrate > 0 else { continue }
            
            let quality: [String: Any] = [
                "height": height,
                "width": width,
                "bitrate": bitrate,
                "averageBitrate": Int(averageBitRate),
                "frameRate": videoAttributes.nominalFrameRate ?? 0,
                "codec": codecTypeToString(videoAttributes.codecTypes.first ?? 0)
            ]
            
            qualities.append(quality)
        }
        
        return qualities
    }
    
    func filterAllowedQualities(_ qualities: [[String: Any]], allowed: [Int]) -> [[String: Any]] {
        var qualityMap: [Int: [String: Any]] = [:]
        
        for quality in qualities {
            guard let height = quality["height"] as? Int,
                  allowed.contains(height),
                  let bitrate = quality["bitrate"] as? Int else { continue }
            
            if let existing = qualityMap[height],
               let existingBitrate = existing["bitrate"] as? Int {
                if bitrate > existingBitrate {
                    qualityMap[height] = quality
                }
            } else {
                qualityMap[height] = quality
            }
        }
        
        // Sort by height descending
        return qualityMap.values.sorted { quality1, quality2 in
            let height1 = quality1["height"] as? Int ?? 0
            let height2 = quality2["height"] as? Int ?? 0
            return height1 > height2
        }
    }
    
    func isDolbyVisionVariant(_ variant: AVAssetVariant) -> Bool {
        guard let videoAttributes = variant.videoAttributes else { return false }
        
        // Check codec types for Dolby Vision identifiers
        for codecType in videoAttributes.codecTypes {
            let codecString = codecTypeToString(codecType).lowercased()
            
            // Dolby Vision codec identifiers
            if codecString.contains("dvhe") ||  // Dolby Vision HEVC
               codecString.contains("dvh1") ||  // Dolby Vision profile 1
               codecString.contains("dav1") ||  // Dolby Vision AV1
               codecString.contains("dvav") {   // Dolby Vision AV1
                return true
            }
        }
        
        return false
    }
    
    func codecTypeToString(_ codecType: CMVideoCodecType) -> String {
        switch codecType {
        case kCMVideoCodecType_H264:
            return "H.264"
        case kCMVideoCodecType_HEVC:
            return "H.265/HEVC"
        case kCMVideoCodecType_VP9:
            return "VP9"
        case kCMVideoCodecType_AV1:
            return "AV1"
        default:
            let chars = [
                Character(UnicodeScalar((codecType >> 24) & 0xFF)!),
                Character(UnicodeScalar((codecType >> 16) & 0xFF)!),
                Character(UnicodeScalar((codecType >> 8) & 0xFF)!),
                Character(UnicodeScalar(codecType & 0xFF)!)
            ]
            return String(chars)
        }
    }
}
