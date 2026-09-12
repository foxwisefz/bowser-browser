import AppKit

// Only C scalars, C function pointers, and retained Objective-C NSView pointers
// cross this boundary. Every admitted library remains mapped until host exit.
public typealias Event = @convention(c) @Sendable (Int64, Int64) -> Void
#if V2
let increment: Int64 = 2
#else
let increment: Int64 = 1
#endif
@MainActor final class ModuleView: NSView {
    var counter: Int64
    let generation: Int64
    let event: Event
    let label = NSTextField(labelWithString: "")
    let button = NSButton(title: "Increment", target: nil, action: nil)
    init(counter: Int64, generation: Int64, event: @escaping Event) {
        self.counter = counter; self.generation = generation; self.event = event
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 60))
        label.frame = NSRect(x: 16, y: 20, width: 540, height: 24)
        label.stringValue = "Native module +\(increment) · preserved counter \(counter)"
        label.textColor = increment == 1 ? .systemBlue : .systemOrange
        button.frame = NSRect(x: 620, y: 14, width: 140, height: 32)
        button.target = self; button.action = #selector(clicked)
        addSubview(label); addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    @objc func clicked() {
        counter += increment
        label.stringValue = "Native module +\(increment) · counter \(counter)"
        event(generation, counter)
        // Intentionally survives retirement: host must reject this stale event.
        let send = event, stamp = generation, value = counter
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { send(stamp, value) }
    }
}
@_cdecl("module_abi") public func abi() -> Int32 {
#if BAD_ABI
    return 99
#else
    return 1
#endif
}
@_cdecl("module_create") public func create(_ counter: Int64, _ generation: Int64, _ event: @escaping Event) -> UnsafeMutableRawPointer? {
#if FAIL_CREATE
    return nil
#else
    UnsafeMutableRawPointer(bitPattern: MainActor.assumeIsolated { UInt(bitPattern: Unmanaged.passRetained(ModuleView(counter: counter, generation: generation, event: event)).toOpaque()) })
#endif
}
@_cdecl("module_step") public func step(_ pointer: UnsafeMutableRawPointer) {
    let address = UInt(bitPattern: pointer)
    MainActor.assumeIsolated { Unmanaged<ModuleView>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue().button.performClick(nil) }
}
@_cdecl("module_read") public func read(_ pointer: UnsafeMutableRawPointer) -> Int64 {
    let address = UInt(bitPattern: pointer)
    return MainActor.assumeIsolated { Unmanaged<ModuleView>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue().counter }
}
@_cdecl("module_destroy") public func destroy(_ pointer: UnsafeMutableRawPointer) {
    let address = UInt(bitPattern: pointer)
    MainActor.assumeIsolated {
        let value = Unmanaged<ModuleView>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!)
        value.takeUnretainedValue().removeFromSuperview()
        value.release()
    }
}

// Explicit health rejection after activation, not recovery from a process crash.
@_cdecl("module_healthy") public func healthy() -> Int32 {
#if BAD_HEALTH
    return 0
#else
    return 1
#endif
}
