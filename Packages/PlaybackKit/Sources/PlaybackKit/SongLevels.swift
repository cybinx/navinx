import Foundation

/// A song's loudness in three bands (bass, middle, treble), as the server's `/eq` sends it
/// (C20, D89, C27; `levels.py` in `Server/panel`): 30 frames a second, each band 0…255, already scaled to
/// the song and smoothed like a meter (a quick rise, a slower fall), so it's only drawn here.
///
/// The file: `NXLV`, version 1, the band count (3), frames a second (UInt16 LE), the frame count
/// (UInt32 LE), then the frames, three bytes each.
public struct SongLevels: Sendable, Equatable {
    public static let bandCount = 3

    public let framesPerSecond: Double
    /// Frame after frame: bass, middle, treble.
    let values: [UInt8]

    public var frameCount: Int { values.count / Self.bandCount }
    public var duration: TimeInterval { Double(frameCount) / framesPerSecond }

    /// Nil when the data isn't a levels file of this version.
    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("NXLV".utf8), bytes[4] == 1,
              Int(bytes[5]) == Self.bandCount else { return nil }
        let fps = Int(bytes[6]) | Int(bytes[7]) << 8
        let count = (0..<4).reduce(0) { $0 | Int(bytes[8 + $1]) << (8 * $1) }
        guard fps > 0, count > 0, bytes.count == 12 + count * Self.bandCount else { return nil }
        framesPerSecond = Double(fps)
        values = Array(bytes[12...])
    }

    /// For tests: `frames` of three values each.
    public init(framesPerSecond: Double, frames: [[UInt8]]) {
        self.framesPerSecond = framesPerSecond
        values = frames.flatMap { $0 }
    }

    /// The three bands at `seconds` into the song, 0…1, between the two nearest frames (a frame's
    /// value sits at its middle). Past the end, silence.
    public func levels(at seconds: TimeInterval) -> SIMD3<Float> {
        guard frameCount > 0, seconds.isFinite, seconds >= 0, seconds < duration + 1 / framesPerSecond else {
            return .zero
        }
        let place = max(seconds * framesPerSecond - 0.5, 0)
        let first = min(Int(place), frameCount - 1)
        let second = min(first + 1, frameCount - 1)
        let along = Float(place - Double(first))
        return frame(first) * (1 - along) + frame(second) * along
    }

    private func frame(_ index: Int) -> SIMD3<Float> {
        let start = index * Self.bandCount
        return SIMD3(Float(values[start]), Float(values[start + 1]), Float(values[start + 2])) / 255
    }
}
