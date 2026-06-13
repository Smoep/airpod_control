import AppKit
import Carbon
import CoreAudio
import Foundation

enum GestureShortcutExecutor {
    private static let volumeStep = 6

    static func canExecuteWithoutKeyboardPermissions(_ shortcut: GestureShortcut) -> Bool {
        let k = shortcut.key.lowercased()
        // Volume/brightness use media keys — no Accessibility needed.
        // Ctrl+Arrow uses osascript subprocess — no Accessibility needed.
        if k == "volume_up" || k == "volume_down" { return true }
        if shortcut.control && !shortcut.command && !shortcut.option {
            if k == "left" || k == "right" { return true }
        }
        return false
    }

    @MainActor
    static func testVolume(up: Bool, store: LiveSensorStore) {
        let shortcut = GestureShortcut(key: up ? "volume_up" : "volume_down", command: false, shift: false, option: false, control: false)
        var trigger = GestureTrigger()
        trigger.type = .keyboardShortcut
        trigger.shortcut = shortcut
        GestureTriggerExecutor.execute(trigger, using: store)
    }

    static func execute(_ shortcut: GestureShortcut) -> Bool {
        dbgLog("ENTRY shortcut_execute key=\(shortcut.key) command=\(shortcut.command) shift=\(shortcut.shift) option=\(shortcut.option) control=\(shortcut.control)")
        guard !shortcut.key.isEmpty else {
            dbgLog("BAIL shortcut_execute reason=empty_key")
            return false
        }

        if executeSystemMediaKeyIfNeeded(shortcut.key.lowercased()) {
            dbgLog("DONE shortcut_execute result=media_key key=\(shortcut.key)")
            return true
        }

        // Ctrl+Arrow: use osascript subprocess to send System Events key stroke.
        // CGEvent injection cannot trigger Mission Control from user space.
        if shortcut.control && !shortcut.command && !shortcut.option {
            let k = shortcut.key.lowercased()
            if k == "left" { return switchDesktopSpace(right: false) }
            if k == "right" { return switchDesktopSpace(right: true) }
        }

        guard let keyCode = keyCodeForCharacter(shortcut.key.lowercased()) else {
            dbgLog("BAIL shortcut_execute reason=unknown_key key=\(shortcut.key)")
            return false
        }

        var flags = CGEventFlags()
        if shortcut.command { flags.insert(.maskCommand) }
        if shortcut.shift { flags.insert(.maskShift) }
        if shortcut.option { flags.insert(.maskAlternate) }
        if shortcut.control { flags.insert(.maskControl) }

        // nil source makes the event appear hardware-originated so system-level
        // interceptors like Mission Control (Ctrl+Arrow) process it instead of
        // passing it straight to the front app.
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            dbgLog("BAIL shortcut_execute reason=cg_event_create_failed keyCode=\(keyCode)")
            return false
        }
        dbgLog("EXTERNAL CGEvent.init keyboardEventSource=nil virtualKey=\(keyCode) keyDown=true return=created")
        dbgLog("EXTERNAL CGEvent.init keyboardEventSource=nil virtualKey=\(keyCode) keyDown=false return=created")
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        dbgLog("EXTERNAL CGEvent.post tap=cghidEventTap keyCode=\(keyCode) keyDown=true flags=\(flags.rawValue) return=posted")
        keyUp.post(tap: .cghidEventTap)
        dbgLog("EXTERNAL CGEvent.post tap=cghidEventTap keyCode=\(keyCode) keyDown=false flags=\(flags.rawValue) return=posted")
        dbgLog("DONE shortcut_execute result=posted key=\(shortcut.key) keyCode=\(keyCode)")
        return true
    }

    // Spawn osascript as a subprocess so macOS shows an Automation permission
    // dialog attributed to this app if needed. NSAppleScript uses the same TCC
    // path but Process() is more reliable at triggering the first-run prompt.
    private static func switchDesktopSpace(right: Bool) -> Bool {
        dbgLog("ENTRY switch_desktop_space right=\(right)")
        let keyCode = right ? "124" : "123"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to key code \(keyCode) using {control down}"]
        do {
            // Fire-and-forget: do NOT call waitUntilExit() here. waitUntilExit blocks
            // the calling queue (main) for 50-200ms while osascript spawns and runs.
            // When invoked from the per-frame continuous gesture pipeline that stall
            // batches CoreMotion callbacks and makes the cursor feel sluggish.
            // The terminationHandler is just to ensure the Process is reaped without
            // blocking; we cannot report success synchronously, so we optimistically
            // return true once spawn succeeded.
            task.terminationHandler = { _ in }
            try task.run()
            dbgLog("EXTERNAL Process.run executable=/usr/bin/osascript args=\(task.arguments ?? []) return=spawned")
            dbgLog("DONE switch_desktop_space result=spawned right=\(right)")
            return true
        } catch {
            dbgLog("BAIL switch_desktop_space reason=spawn_failed error=\(error.localizedDescription)")
            return false
        }
    }

    private static func executeSystemMediaKeyIfNeeded(_ key: String) -> Bool {
        dbgLog("ENTRY media_key_execute key=\(key)")
        let mediaKeyCode: Int32

        switch key {
        case "volume_up":
            mediaKeyCode = NX_KEYTYPE_SOUND_UP
        case "volume_down":
            mediaKeyCode = NX_KEYTYPE_SOUND_DOWN
        case "brightness_up":
            mediaKeyCode = NX_KEYTYPE_BRIGHTNESS_UP
        case "brightness_down":
            mediaKeyCode = NX_KEYTYPE_BRIGHTNESS_DOWN
        default:
            dbgLog("BAIL media_key_execute reason=not_media_key key=\(key)")
            return false
        }

        let didPostDown = postSystemMediaKey(mediaKeyCode, isKeyDown: true)
        let didPostUp = postSystemMediaKey(mediaKeyCode, isKeyDown: false)
        let success = didPostDown && didPostUp
        dbgLog("DONE media_key_execute key=\(key) mediaKeyCode=\(mediaKeyCode) down=\(didPostDown) up=\(didPostUp) success=\(success)")
        return success
    }

    private static func postSystemMediaKey(_ keyCode: Int32, isKeyDown: Bool) -> Bool {
        let keyState = isKeyDown ? 0xA : 0xB
        let data1 = (Int(keyCode) << 16) | (keyState << 8)
        let flags = NSEvent.ModifierFlags(rawValue: isKeyDown ? 0xA00 : 0xB00)
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )

        guard let cgEvent = event?.cgEvent else {
            dbgLog("BAIL media_key_post reason=nsevent_create_failed mediaKeyCode=\(keyCode) isKeyDown=\(isKeyDown) data1=\(data1)")
            return false
        }
        dbgLog("EXTERNAL NSEvent.otherEvent type=systemDefined subtype=8 mediaKeyCode=\(keyCode) isKeyDown=\(isKeyDown) data1=\(data1) return=created")

        cgEvent.post(tap: CGEventTapLocation.cghidEventTap)
        dbgLog("EXTERNAL CGEvent.post tap=cghidEventTap mediaKeyCode=\(keyCode) isKeyDown=\(isKeyDown) return=posted")
        return true
    }

    private static func adjustSystemOutputVolume(by delta: Int) -> Bool {
        dbgLog("ENTRY volume_adjust delta=\(delta)")
        guard let currentVolume = currentSystemOutputVolume() else {
            dbgLog("BAIL volume_adjust reason=current_volume_unavailable delta=\(delta)")
            return false
        }

        let nextVolume = min(max(currentVolume + delta, 0), 100)
        guard nextVolume != currentVolume else {
            dbgLog("DONE volume_adjust result=unchanged current=\(currentVolume)")
            return true
        }

        let didSet = setSystemOutputVolume(nextVolume)
        dbgLog("DONE volume_adjust current=\(currentVolume) next=\(nextVolume) return=\(didSet)")
        return didSet
    }

    private static func currentSystemOutputVolume() -> Int? {
        dbgLog("ENTRY volume_read")
        if let scalarVolume = currentSystemOutputVolumeScalar() {
            let percent = Int((Double(scalarVolume) * 100).rounded())
            dbgLog("DONE volume_read source=CoreAudio scalar=\(scalarVolume) percent=\(percent)")
            return percent
        }

        var error: NSDictionary?
        let script = NSAppleScript(source: "output volume of (get volume settings)")
        let result = script?.executeAndReturnError(&error)
        dbgLog("EXTERNAL NSAppleScript.execute source=read_output_volume error=\(error?.description ?? "nil") result=\(result?.stringValue ?? "nil")")
        if error != nil {
            dbgLog("BAIL volume_read reason=apple_script_error error=\(error?.description ?? "nil")")
            return nil
        }

        let percent = Int(result?.int32Value ?? -1)
        dbgLog("DONE volume_read source=AppleScript percent=\(percent)")
        return percent
    }

    private static func setSystemOutputVolume(_ volume: Int) -> Bool {
        let clampedVolume = min(max(volume, 0), 100)
        dbgLog("ENTRY volume_set requested=\(volume) clamped=\(clampedVolume)")

        if setSystemOutputVolumeScalar(Float32(clampedVolume) / 100) {
            dbgLog("DONE volume_set source=CoreAudio percent=\(clampedVolume)")
            return true
        }

        var error: NSDictionary?
        let script = NSAppleScript(source: "set volume output volume \(clampedVolume)")
        script?.executeAndReturnError(&error)
        dbgLog("EXTERNAL NSAppleScript.execute source=set_output_volume percent=\(clampedVolume) error=\(error?.description ?? "nil")")
        dbgLog("DONE volume_set source=AppleScript percent=\(clampedVolume) return=\(error == nil)")
        return error == nil
    }

    private static func currentSystemOutputVolumeScalar() -> Float32? {
        guard let deviceID = defaultOutputDeviceID() else {
            return nil
        }

        if let mainVolume = readOutputVolumeScalar(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            return mainVolume
        }

        let channelVolumes = outputChannelElements.compactMap {
            readOutputVolumeScalar(deviceID: deviceID, element: $0)
        }

        guard !channelVolumes.isEmpty else {
            return nil
        }

        let total = channelVolumes.reduce(Float32.zero, +)
        return total / Float32(channelVolumes.count)
    }

    private static func setSystemOutputVolumeScalar(_ scalar: Float32) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else {
            return false
        }

        let clampedScalar = min(max(scalar, 0), 1)
        if writeOutputVolumeScalar(deviceID: deviceID, element: kAudioObjectPropertyElementMain, scalar: clampedScalar) {
            return true
        }

        var didSetAnyChannel = false
        for element in outputChannelElements {
            didSetAnyChannel = writeOutputVolumeScalar(deviceID: deviceID, element: element, scalar: clampedScalar) || didSetAnyChannel
        }
        return didSetAnyChannel
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        dbgLog("EXTERNAL AudioObjectGetPropertyData selector=defaultOutputDevice status=\(status) deviceID=\(deviceID)")

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            dbgLog("BAIL default_output_device reason=status_or_unknown status=\(status) deviceID=\(deviceID)")
            return nil
        }

        return deviceID
    }

    private static func readOutputVolumeScalar(deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            dbgLog("EXTERNAL AudioObjectHasProperty deviceID=\(deviceID) selector=volumeScalar element=\(element) return=false")
            return nil
        }
        dbgLog("EXTERNAL AudioObjectHasProperty deviceID=\(deviceID) selector=volumeScalar element=\(element) return=true")

        var volume = Float32.zero
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        dbgLog("EXTERNAL AudioObjectGetPropertyData selector=volumeScalar deviceID=\(deviceID) element=\(element) status=\(status) volume=\(volume)")
        guard status == noErr else {
            return nil
        }

        return volume
    }

    private static func writeOutputVolumeScalar(
        deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement,
        scalar: Float32
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            dbgLog("EXTERNAL AudioObjectHasProperty deviceID=\(deviceID) selector=volumeScalar element=\(element) return=false")
            return false
        }
        dbgLog("EXTERNAL AudioObjectHasProperty deviceID=\(deviceID) selector=volumeScalar element=\(element) return=true")

        var settable = DarwinBoolean(false)
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        dbgLog("EXTERNAL AudioObjectIsPropertySettable deviceID=\(deviceID) element=\(element) status=\(settableStatus) settable=\(settable.boolValue)")
        guard settableStatus == noErr, settable.boolValue else {
            return false
        }

        var mutableScalar = scalar
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mutableScalar)
        dbgLog("EXTERNAL AudioObjectSetPropertyData selector=volumeScalar deviceID=\(deviceID) element=\(element) scalar=\(mutableScalar) status=\(status)")
        return status == noErr
    }

    private static var outputChannelElements: [AudioObjectPropertyElement] {
        [1, 2]
    }

    private static func keyCodeForCharacter(_ key: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
            "k": 40, "n": 45, "m": 46, "o": 31,
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
            "8": 28, "9": 25, "0": 29,
            "-": 27, "=": 24, "[": 33, "]": 30, "'": 39, ";": 41, "\\": 42,
            ",": 43, "/": 44, ".": 47, "`": 50,
            "tab": 48, "space": 49, " ": 49, "return": 36, "escape": 53,
            "delete": 51, "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]
        return map[key]
    }
}
