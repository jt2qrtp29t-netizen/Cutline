import CoreMedia
import Metal
import VideoToolbox

/// What this Mac's media hardware can do, for the Performance parameters.
nonisolated enum HardwareInfo {
    struct Codec: Identifiable, Sendable {
        let name: String
        let type: CMVideoCodecType
        var id: CMVideoCodecType { type }
    }

    static let codecs = [
        Codec(name: "H.264", type: kCMVideoCodecType_H264),
        Codec(name: "HEVC", type: kCMVideoCodecType_HEVC),
        Codec(name: "ProRes", type: kCMVideoCodecType_AppleProRes422),
        Codec(name: "AV1", type: kCMVideoCodecType_AV1),
    ]

    /// The GPU that draws frames.
    static var gpuName: String {
        MTLCreateSystemDefaultDevice()?.name ?? "Unknown"
    }

    static func hasHardwareDecoder(for codec: CMVideoCodecType) -> Bool {
        VTIsHardwareDecodeSupported(codec)
    }

    /// Codec types this Mac encodes in hardware.
    static let hardwareEncoders: Set<CMVideoCodecType> = {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else { return [] }
        return Set(encoders.compactMap { encoder -> CMVideoCodecType? in
            guard encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool == true,
                  let type = encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber else { return nil }
            return CMVideoCodecType(truncating: type)
        })
    }()
}
