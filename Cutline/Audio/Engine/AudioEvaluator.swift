import AVFoundation

/// The one format everything inside the audio graph uses. Sources are converted to it
/// on the way in (`AudioSourceCache`), so no node ever resamples.
nonisolated enum AudioGraphFormat {
    static let sampleRate = 48_000.0
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    /// Automation is evaluated every this many samples, at fixed timeline positions,
    /// and interpolated in between, so playback and export compute the same values.
    static let controlInterval: Int64 = 32
    /// Changes that aren't automation (a fader drag, mute, solo) glide over this many
    /// samples (about 5 ms) so they never click.
    static let rampLength = 256

    static func sample(of time: Time) -> Int64 { Int64((time.seconds * sampleRate).rounded()) }
    static func seconds(ofSample sample: Int64) -> Double { Double(sample) / sampleRate }
}

/// How pan spreads a signal across left and right.
nonisolated enum PanLaw {
    /// Gains for left and right. Mono sources pan with constant power (−3 dB each at
    /// center); stereo sources balance (the far side is turned down, the near side kept),
    /// exactly as clips have always sounded in Cutline.
    static func gains(pan: Double, monoSource: Bool) -> (left: Double, right: Double) {
        let p = min(max(pan, -1), 1)
        if monoSource {
            let angle = (p + 1) * .pi / 4
            return (cos(angle), sin(angle))
        }
        return (p <= 0 ? 1 : 1 - p, p >= 0 ? 1 : 1 + p)
    }
}

/// Everything about a clip's level over time: clip gain, volume (with keyframes),
/// pan (with keyframes), fades, and whether mute/solo lets it play. The single place
/// these are computed, for playback, scrubbing, export and waveform drawing.
nonisolated struct ClipEnvelope: Sendable {
    let clipID: UUID
    let start: Time
    let end: Time
    let gain: Double
    let volume: Double
    let volumeFrames: [Keyframe]
    let pan: Double
    let panFrames: [Keyframe]
    let fadeIn: AudioFade
    let fadeOut: AudioFade
    let monoSource: Bool
    let isActive: Bool

    init(_ clip: Clip, isActive: Bool, monoSource: Bool) {
        clipID = clip.id
        start = clip.start
        end = clip.end
        gain = AudioLevel.linear(fromDB: clip.gainDB)
        volume = clip.volume
        volumeFrames = clip.animation.keyframes(for: .volume)
        pan = clip.pan
        panFrames = clip.animation.keyframes(for: .pan)
        fadeIn = clip.fadeIn
        fadeOut = clip.fadeOut
        self.monoSource = monoSource
        self.isActive = isActive
    }

    /// Volume at a timeline time (keyframes are relative to the clip's start).
    func volume(at time: Time) -> Double {
        volumeFrames.isEmpty ? volume : ClipAnimation.interpolate(volumeFrames, atOffset: time - start)
    }

    func pan(at time: Time) -> Double {
        panFrames.isEmpty ? pan : ClipAnimation.interpolate(panFrames, atOffset: time - start)
    }

    /// The fades' combined gain at a timeline time.
    func fadeGain(at time: Time) -> Double {
        var g = 1.0
        if fadeIn.isActive {
            g *= fadeIn.curve.gain((time - start).seconds / fadeIn.duration.seconds)
        }
        if fadeOut.isActive {
            g *= fadeOut.curve.gain((end - time).seconds / fadeOut.duration.seconds)
        }
        return g
    }

    /// Overall linear level (before pan): clip gain × volume × fades, or 0 when muted.
    func level(at time: Time) -> Double {
        guard isActive else { return 0 }
        return gain * volume(at: time) * fadeGain(at: time)
    }

    /// Left and right gains at a timeline time.
    func gains(at time: Time) -> (left: Double, right: Double) {
        let level = level(at: time)
        guard level > 0 else { return (0, 0) }
        let (l, r) = PanLaw.gains(pan: pan(at: time), monoSource: monoSource)
        return (level * l, level * r)
    }
}

/// A track's fader and pan over time, and whether mute/solo lets it play.
nonisolated struct TrackEnvelope: Sendable {
    let trackID: UUID
    let volumeDB: Double
    let volumeFrames: [Keyframe]
    let pan: Double
    let panFrames: [Keyframe]
    let isActive: Bool

    init(_ track: Track, isActive: Bool) {
        trackID = track.id
        volumeDB = track.audio.volumeDB
        volumeFrames = track.audio.keyframes[AudioParameter.volume.id] ?? []
        pan = track.audio.pan
        panFrames = track.audio.keyframes[AudioParameter.pan.id] ?? []
        self.isActive = isActive
    }

    func volumeDB(at time: Time) -> Double {
        volumeFrames.isEmpty ? volumeDB : ClipAnimation.interpolate(volumeFrames, atOffset: time)
    }

    func pan(at time: Time) -> Double {
        panFrames.isEmpty ? pan : ClipAnimation.interpolate(panFrames, atOffset: time)
    }

    func gains(at time: Time) -> (left: Double, right: Double) {
        guard isActive else { return (0, 0) }
        let level = AudioLevel.linear(fromDB: volumeDB(at: time))
        // The track carries a stereo mix, so its pan is a balance.
        let (l, r) = PanLaw.gains(pan: pan(at: time), monoSource: false)
        return (level * l, level * r)
    }
}

/// The master fader over time.
nonisolated struct MasterEnvelope: Sendable {
    let volumeDB: Double
    let volumeFrames: [Keyframe]

    init(_ master: MasterAudio) {
        volumeDB = master.volumeDB
        volumeFrames = master.keyframes[AudioParameter.volume.id] ?? []
    }

    func gain(at time: Time) -> Double {
        AudioLevel.linear(fromDB: volumeFrames.isEmpty ? volumeDB : ClipAnimation.interpolate(volumeFrames, atOffset: time))
    }
}
