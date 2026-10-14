// Volume (CoreAudio), brilho da tela embutida (DisplayServices) e teclas de mídia.

import AppKit
import CoreAudio
import AudioToolbox

enum SystemControls {
    // MARK: volume

    private static func outputDevice() -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    static var volume: Float? {
        guard let dev = outputDevice() else { return nil }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func setVolume(_ v: Float) {
        guard let dev = outputDevice() else { return }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var val = Float32(min(max(v, 0), 1))
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &val)
        if val > 0, muted { setMuted(false) }
    }

    static var muted: Bool {
        guard let dev = outputDevice() else { return false }
        var addr = address(kAudioDevicePropertyMute)
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr && m != 0
    }

    static func setMuted(_ on: Bool) {
        guard let dev = outputDevice() else { return }
        var addr = address(kAudioDevicePropertyMute)
        var m = UInt32(on ? 1 : 0)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }

    // MARK: brilho (framework privado DisplayServices; só a tela embutida — monitores externos usam DDC)

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: GetFn? = dlsym(ds, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = dlsym(ds, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }

    private static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    static var brightness: Float? {
        var b: Float = 0
        guard let getFn, getFn(display, &b) == 0 else { return nil }
        return b
    }

    static func setBrightness(_ v: Float) {
        _ = setFn?(display, min(max(v, 0), 1))
    }

    /// "S volume brilho mudo" — -1 quando não disponível.
    static var state: String {
        String(format: "S %.3f %.3f %d", volume ?? -1, brightness ?? -1, muted ? 1 : 0)
    }

    // MARK: teclas de mídia (NX_KEYTYPE_*: 16 play/pause, 17 próxima, 18 anterior)

    static func mediaKey(_ key: Int) {
        for down in [true, false] {
            let flags = down ? 0xa00 : 0xb00
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (key << 16) | flags, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
