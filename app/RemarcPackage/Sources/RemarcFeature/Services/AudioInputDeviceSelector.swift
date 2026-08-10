import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation

struct AudioInputDeviceCandidate: Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    let manufacturer: String
    let uid: String
    let modelUID: String
    let transportType: UInt32
    let inputChannelCount: UInt32
    let isAlive: Bool
}

final class AudioInputDeviceOverride: @unchecked Sendable {
    private let previousDeviceID: AudioDeviceID?
    private let previousDeviceName: String?
    private let selectedDeviceID: AudioDeviceID
    private let selectedDeviceName: String
    private let shouldRestore: Bool
    private let lock = NSLock()
    private var didRestore = false

    fileprivate init(
        previousDeviceID: AudioDeviceID?,
        previousDeviceName: String?,
        selectedDeviceID: AudioDeviceID,
        selectedDeviceName: String,
        shouldRestore: Bool
    ) {
        self.previousDeviceID = previousDeviceID
        self.previousDeviceName = previousDeviceName
        self.selectedDeviceID = selectedDeviceID
        self.selectedDeviceName = selectedDeviceName
        self.shouldRestore = shouldRestore
    }

    func restore() {
        lock.lock()
        guard !didRestore else {
            lock.unlock()
            return
        }
        didRestore = true
        lock.unlock()

        guard shouldRestore, let previousDeviceID else { return }

        if AudioInputDeviceSelector.setDefaultInputDevice(previousDeviceID) {
            debugLog("AudioInputDeviceSelector: Restored default input to \(previousDeviceName ?? "previous device")")
        } else {
            debugLog("AudioInputDeviceSelector: Failed to restore default input after using \(selectedDeviceName)")
        }
    }
}

enum AudioInputDeviceSelector {
    static func activatePreferredDefaultInput() -> AudioInputDeviceOverride? {
        let devices = inputDevices()
        guard let preferred = preferredDevice(from: devices) else {
            debugLog("AudioInputDeviceSelector: No preferred input found; keeping system default")
            return nil
        }

        let currentDeviceID = defaultInputDeviceID()
        let currentDevice = currentDeviceID.flatMap { id in devices.first { $0.id == id } }
        if currentDeviceID == preferred.id {
            debugLog("AudioInputDeviceSelector: Preferred input already default: \(preferred.displayName)")
            return AudioInputDeviceOverride(
                previousDeviceID: currentDeviceID,
                previousDeviceName: currentDevice?.displayName,
                selectedDeviceID: preferred.id,
                selectedDeviceName: preferred.displayName,
                shouldRestore: false
            )
        }

        guard setDefaultInputDevice(preferred.id) else {
            debugLog("AudioInputDeviceSelector: Failed to set default input to \(preferred.displayName)")
            return nil
        }

        debugLog("AudioInputDeviceSelector: Temporarily set default input to \(preferred.displayName) (was \(currentDevice?.displayName ?? "unknown"))")
        return AudioInputDeviceOverride(
            previousDeviceID: currentDeviceID,
            previousDeviceName: currentDevice?.displayName,
            selectedDeviceID: preferred.id,
            selectedDeviceName: preferred.displayName,
            shouldRestore: currentDeviceID != nil
        )
    }

    static func applyPreferredDevice(to inputNode: AVAudioInputNode) {
        let devices = inputDevices()
        guard let preferred = preferredDevice(from: devices) else {
            debugLog("AudioInputDeviceSelector: No preferred input found; using system default")
            return
        }

        guard let audioUnit = inputNode.audioUnit else {
            debugLog("AudioInputDeviceSelector: Input node has no AudioUnit; using system default")
            return
        }

        var deviceID = preferred.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            debugLog("AudioInputDeviceSelector: Failed to select \(preferred.displayName) (status=\(status)); using system default")
            return
        }

        var actualDeviceID = AudioDeviceID(0)
        var actualSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let actualStatus = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &actualDeviceID,
            &actualSize
        )

        if actualStatus == noErr, actualDeviceID != preferred.id {
            let actualName = devices.first { $0.id == actualDeviceID }?.displayName ?? "\(actualDeviceID)"
            debugLog("AudioInputDeviceSelector: Requested \(preferred.displayName), AudioUnit reports \(actualName)")
        } else {
            debugLog("AudioInputDeviceSelector: Selected \(preferred.displayName)")
        }
    }

    static func preferredDevice(from devices: [AudioInputDeviceCandidate]) -> AudioInputDeviceCandidate? {
        let usable = devices.filter { $0.isAlive && $0.inputChannelCount > 0 }

        if let dedicated = usable
            .filter({ isDedicatedExternalMicrophone($0) })
            .max(by: isLessPreferred) {
            return dedicated
        }

        if let builtIn = usable
            .filter({ isBuiltInMicrophone($0) })
            .max(by: isLessPreferred) {
            return builtIn
        }

        return usable
            .filter { !shouldAvoid($0) && !isVirtualOrAggregate($0) }
            .max(by: isLessPreferred)
    }

    fileprivate static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
        guard status == noErr else {
            debugLog("AudioInputDeviceSelector: AudioObjectSetPropertyData default input failed (status=\(status))")
            return false
        }
        return true
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func inputDevices() -> [AudioInputDeviceCandidate] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else {
            debugLog("AudioInputDeviceSelector: Could not read audio devices (status=\(status))")
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: deviceCount)
        status = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return kAudio_ParamError }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }
        guard status == noErr else {
            debugLog("AudioInputDeviceSelector: Could not enumerate audio devices (status=\(status))")
            return []
        }

        return deviceIDs.compactMap(candidate(for:))
    }

    private static func candidate(for deviceID: AudioDeviceID) -> AudioInputDeviceCandidate? {
        let channelCount = inputChannelCount(for: deviceID)
        guard channelCount > 0 else { return nil }

        let name = stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "Unknown Input"
        let manufacturer = stringProperty(kAudioObjectPropertyManufacturer, for: deviceID) ?? ""
        let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) ?? ""
        let modelUID = stringProperty(kAudioDevicePropertyModelUID, for: deviceID) ?? ""
        let transportType = uint32Property(kAudioDevicePropertyTransportType, for: deviceID) ?? 0
        let isAlive = (uint32Property(kAudioDevicePropertyDeviceIsAlive, for: deviceID) ?? 1) != 0

        return AudioInputDeviceCandidate(
            id: deviceID,
            name: name,
            manufacturer: manufacturer,
            uid: uid,
            modelUID: modelUID,
            transportType: transportType,
            inputChannelCount: channelCount,
            isAlive: isAlive
        )
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawBufferList)
        guard status == noErr else { return 0 }

        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(audioBufferList)
            .reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return nil }
        return value
    }

    private static func isLessPreferred(_ lhs: AudioInputDeviceCandidate, _ rhs: AudioInputDeviceCandidate) -> Bool {
        let leftScore = preferenceScore(for: lhs)
        let rightScore = preferenceScore(for: rhs)
        if leftScore != rightScore { return leftScore < rightScore }
        if lhs.inputChannelCount != rhs.inputChannelCount {
            return lhs.inputChannelCount < rhs.inputChannelCount
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
    }

    private static func preferenceScore(for device: AudioInputDeviceCandidate) -> Int {
        if shouldAvoid(device) { return Int.min / 2 }

        var score = 0
        if isDedicatedExternalMicrophone(device) { score += 1_000 }
        if isBuiltInMicrophone(device) { score += 700 }
        if isPhysicalExternalInput(device) { score += 500 }

        switch device.transportType {
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            score += 100
        case kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeAVB:
            score += 80
        case kAudioDeviceTransportTypeBuiltIn:
            score += 60
        default:
            break
        }

        score += min(Int(device.inputChannelCount), 8)
        return score
    }

    private static func isDedicatedExternalMicrophone(_ device: AudioInputDeviceCandidate) -> Bool {
        guard !shouldAvoid(device),
              !isBuiltInMicrophone(device),
              !isVirtualOrAggregate(device),
              !containsAny(device.searchText, cameraOrDisplayHints) else {
            return false
        }

        return containsAny(device.searchText, proMicrophoneHints)
    }

    private static func isBuiltInMicrophone(_ device: AudioInputDeviceCandidate) -> Bool {
        guard device.transportType == kAudioDeviceTransportTypeBuiltIn else { return false }
        return containsAny(device.searchText, [
            "built-in microphone",
            "built in microphone",
            "microphone",
            "mic",
            "macbook",
            "mac microphone",
            "internal microphone"
        ])
    }

    private static func isPhysicalExternalInput(_ device: AudioInputDeviceCandidate) -> Bool {
        switch device.transportType {
        case kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeAVB:
            return true
        default:
            return false
        }
    }

    private static func isVirtualOrAggregate(_ device: AudioInputDeviceCandidate) -> Bool {
        switch device.transportType {
        case kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate,
             kAudioDeviceTransportTypeVirtual:
            return true
        default:
            return false
        }
    }

    private static func shouldAvoid(_ device: AudioInputDeviceCandidate) -> Bool {
        switch device.transportType {
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeAirPlay,
             kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            return true
        default:
            break
        }

        return containsAny(device.searchText, [
            "airpods",
            "air pods",
            "beats",
            "bluetooth",
            "headset",
            "hands-free",
            "hands free",
            "iphone microphone",
            "continuity camera"
        ])
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static let proMicrophoneHints = [
        "apollo",
        "audient",
        "audio-technica",
        "at2020",
        "behringer",
        "blue snowball",
        "focusrite",
        "hyperx quadcast",
        "motu",
        "mv7",
        "nt-usb",
        "podmic",
        "rode",
        "samson",
        "scarlett",
        "shure",
        "universal audio",
        "wave",
        "yeti",
        "zoom"
    ]

    private static let cameraOrDisplayHints = [
        "camera",
        "display",
        "hdmi",
        "monitor",
        "webcam"
    ]
}

private extension AudioInputDeviceCandidate {
    var searchText: String {
        "\(name) \(manufacturer) \(uid) \(modelUID)".localizedLowercase
    }

    var displayName: String {
        manufacturer.isEmpty ? name : "\(manufacturer) \(name)"
    }
}
