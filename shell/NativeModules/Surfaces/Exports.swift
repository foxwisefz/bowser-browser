import AppKit
import SwiftUI
import BowserSurfaceKit

public typealias SurfaceEvent = @convention(c) @Sendable (UInt64, UnsafePointer<CChar>) -> Void

@MainActor private func context(_ data: Data) -> SurfaceRenderContext? {
    guard !data.isEmpty, data.count <= 65536,
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let id = value["context"] else { return nil }
    return SurfaceRenderContext.contexts[id]
}
@_cdecl("bowser_toolbar_abi") public func surfaceABI() -> Int32 { 1 }
@_cdecl("bowser_toolbar_create")
public func surfaceCreate(_ bytes: UnsafePointer<UInt8>, _ count: Int32, _ generation: UInt64, _ event: SurfaceEvent) -> UnsafeMutableRawPointer? {
    guard count > 0, count <= 65536 else { return nil }
    let data = Data(bytes: bytes, count: Int(count))
    let address = MainActor.assumeIsolated { () -> UInt in
        guard let context = context(data) else { return 0 }
        let view = NSHostingView(rootView: SurfaceGenerationRoot(context: context, generation: generation) { message in
            guard let data = try? JSONSerialization.data(withJSONObject: message), data.count <= 1_048_576,
                  let text = String(data: data, encoding: .utf8) else { return }
            text.withCString { event(generation, $0) }
        })
        view.identifier = NSUserInterfaceItemIdentifier(context.id)
        return UInt(bitPattern: Unmanaged.passRetained(view).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
}
@_cdecl("bowser_toolbar_update")
public func surfaceUpdate(_ pointer: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>, _ count: Int32) -> Int32 {
    guard count > 0, count <= 65536 else { return 0 }
    let data = Data(bytes: bytes, count: Int(count)), address = UInt(bitPattern: pointer)
    return MainActor.assumeIsolated {
        guard let context = context(data) else { return 0 }
        let view = Unmanaged<NSView>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
        return view.identifier?.rawValue == context.id ? 1 : 0
    }
}
@_cdecl("bowser_toolbar_destroy")
public func surfaceDestroy(_ pointer: UnsafeMutableRawPointer) {
    let address = UInt(bitPattern: pointer)
    MainActor.assumeIsolated {
        let view = Unmanaged<NSView>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeRetainedValue()
        view.removeFromSuperview()
    }
}
