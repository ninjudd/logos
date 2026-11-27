import Testing
@testable import Logos

@Suite struct MicrophoneStartTests {
    // Catches a press held while the last tap's start is still running recording nothing.
    @Test func aPressDuringTheLastTapsStartRecordsWithIt() {
        var microphone = MicrophoneStart()
        let tap = microphone.press()
        microphone.release()
        let hold = microphone.press()
        let arrival = microphone.arrived(1)
        microphone.release()
        let next = microphone.press()
        #expect(tap == .start(id: 1))
        #expect(hold == .adopt)
        #expect(arrival == .wanted)
        #expect(next == .start(id: 2))
    }

    // Catches a recorder kept for a tap released before the microphone started.
    @Test func aStartAfterEveryPressEndedIsUnwanted() {
        var microphone = MicrophoneStart()
        _ = microphone.press()
        microphone.release()
        _ = microphone.press()
        microphone.release()
        let arrival = microphone.arrived(1)
        #expect(arrival == .unwanted)
    }

    // Catches a second start, and a second recorder, for a hotkey that is already down.
    @Test func aPressWhileHoldingIsIgnored() {
        var microphone = MicrophoneStart()
        _ = microphone.press()
        let whileStarting = microphone.press()
        let arrival = microphone.arrived(1)
        let whileRecording = microphone.press()
        #expect(whileStarting == .ignore)
        #expect(arrival == .wanted)
        #expect(whileRecording == .ignore)
    }

    // Catches a start that finishes after its timeout recording the next press,
    // and a timeout that fires after its start finished ending the recording.
    @Test func aTimedOutStartIsAbandoned() {
        var microphone = MicrophoneStart()
        _ = microphone.press()
        let gaveUp = microphone.timedOut(1)
        microphone.release()
        let retry = microphone.press()
        let late = microphone.arrived(1)
        let arrival = microphone.arrived(2)
        let lateTimeout = microphone.timedOut(2)
        #expect(gaveUp)
        #expect(retry == .start(id: 2))
        #expect(late == .abandoned)
        #expect(arrival == .wanted)
        #expect(!lateTimeout)
    }
}
