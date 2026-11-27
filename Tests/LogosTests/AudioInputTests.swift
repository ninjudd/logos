import Foundation
import Testing
@testable import Logos

@Suite struct AudioInputTests {
    private let mac = AudioInput.Device(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isBuiltIn: true)
    private let volt = AudioInput.Device(id: 2, uid: "AppleUSBAudioEngine:UA:Volt 476", name: "Volt 476", isBuiltIn: false)

    // Catches plugging in an audio interface switching Logos to a device with no mic.
    @Test func builtInIgnoresOtherDevices() {
        #expect(AudioInput.resolve(AudioInput.builtIn, among: [volt, mac]) == mac)
    }

    @Test func chosenDeviceIsUsedWhenConnected() {
        #expect(AudioInput.resolve(volt.uid, among: [mac, volt]) == volt)
    }

    // Catches a chosen device that's been unplugged leaving Logos with whatever
    // macOS picked instead of the built-in microphone.
    @Test func disconnectedDeviceFallsBackToBuiltIn() {
        #expect(AudioInput.resolve(volt.uid, among: [mac]) == mac)
    }

    @Test func systemDefaultLeavesTheInputAlone() {
        #expect(AudioInput.resolve(AudioInput.systemDefault, among: [mac, volt]) == nil)
    }

    // A Mac without a built-in microphone, such as a Mac mini, uses the default input.
    @Test func noBuiltInMicrophoneUsesTheDefault() {
        #expect(AudioInput.resolve(AudioInput.builtIn, among: [volt]) == nil)
    }

    @Test func builtInIsTheDefaultSetting() throws {
        #expect(try Config.decode(Data("{}".utf8)).inputDevice == AudioInput.builtIn)
    }
}
