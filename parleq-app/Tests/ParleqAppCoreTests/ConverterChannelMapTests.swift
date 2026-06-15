import XCTest
@testable import ParleqAppCore

/// A1 (lost-dictation fix): a bare multichannel→mono AVAudioConverter silently
/// emits all-zero samples (the peak=0.0000 capture loss). We set an explicit
/// channelMap so each output channel takes a real input channel.
final class ConverterChannelMapTests: XCTestCase {

    func testMonoOutputMapsToFirstInputChannel() {
        // Mono target → take input channel 0 (works for a 1-, 2-, or 3-channel
        // input; the map only depends on the OUTPUT channel count).
        XCTAssertEqual(AudioRecorder.converterChannelMap(outputChannels: 1), [0])
    }

    func testStereoOutputMapsChannelsThrough() {
        // Defensive: if the output were ever stereo, map 0←0, 1←1.
        XCTAssertEqual(AudioRecorder.converterChannelMap(outputChannels: 2), [0, 1])
    }
}
