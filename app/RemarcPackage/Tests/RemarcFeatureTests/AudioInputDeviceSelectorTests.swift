import CoreAudio
import Testing
@testable import RemarcFeature

@Test func smartMicrophoneSelectionPrefersBuiltInMicOverAirPods() {
    let builtIn = candidate(
        id: 1,
        name: "MacBook Pro Microphone",
        manufacturer: "Apple Inc.",
        transportType: kAudioDeviceTransportTypeBuiltIn
    )
    let airPods = candidate(
        id: 2,
        name: "Mete's AirPods Pro",
        manufacturer: "Apple Inc.",
        transportType: kAudioDeviceTransportTypeBluetooth
    )

    #expect(AudioInputDeviceSelector.preferredDevice(from: [airPods, builtIn]) == builtIn)
}

@Test func smartMicrophoneSelectionPrefersDedicatedUsbMicOverBuiltInMic() {
    let builtIn = candidate(
        id: 1,
        name: "MacBook Pro Microphone",
        manufacturer: "Apple Inc.",
        transportType: kAudioDeviceTransportTypeBuiltIn
    )
    let shure = candidate(
        id: 2,
        name: "Shure MV7",
        manufacturer: "Shure",
        transportType: kAudioDeviceTransportTypeUSB,
        channels: 2
    )

    #expect(AudioInputDeviceSelector.preferredDevice(from: [builtIn, shure]) == shure)
}

@Test func smartMicrophoneSelectionDoesNotPromoteWebcamMicOverBuiltInMic() {
    let builtIn = candidate(
        id: 1,
        name: "MacBook Pro Microphone",
        manufacturer: "Apple Inc.",
        transportType: kAudioDeviceTransportTypeBuiltIn
    )
    let webcam = candidate(
        id: 2,
        name: "USB Webcam Microphone",
        manufacturer: "Generic",
        transportType: kAudioDeviceTransportTypeUSB
    )

    #expect(AudioInputDeviceSelector.preferredDevice(from: [webcam, builtIn]) == builtIn)
}

@Test func smartMicrophoneSelectionDoesNotPromoteGenericUsbMicOverBuiltInMic() {
    let builtIn = candidate(
        id: 1,
        name: "MacBook Pro Microphone",
        manufacturer: "Apple Inc.",
        transportType: kAudioDeviceTransportTypeBuiltIn
    )
    let genericExternalMic = candidate(
        id: 2,
        name: "DJI MIC MINI",
        manufacturer: "DJI Technology Co., Ltd.",
        transportType: kAudioDeviceTransportTypeUSB,
        channels: 2
    )

    #expect(AudioInputDeviceSelector.preferredDevice(from: [genericExternalMic, builtIn]) == builtIn)
}

private func candidate(
    id: AudioDeviceID,
    name: String,
    manufacturer: String,
    transportType: UInt32,
    channels: UInt32 = 1,
    isAlive: Bool = true
) -> AudioInputDeviceCandidate {
    AudioInputDeviceCandidate(
        id: id,
        name: name,
        manufacturer: manufacturer,
        uid: "\(manufacturer).\(name).\(id)",
        modelUID: name,
        transportType: transportType,
        inputChannelCount: channels,
        isAlive: isAlive
    )
}
