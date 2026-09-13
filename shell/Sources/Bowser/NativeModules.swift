import AppKit
import Security
import Darwin
import BowserSurfaceKit

enum NativeModuleKind: String {
    case commandToolbar = "command-toolbar", surfaces = "surfaces"
    var executable: String { self == .commandToolbar ? "CommandToolbar" : "SurfaceRenderer" }
    var identifier: String { "com.foxwiseai.bowser." + rawValue }
}

/// Identity of the already mapped stable state library, not a mutable disk file.
/// A renderer compiled against a different library must wait for a host update.
enum SurfaceKitIdentity {
    static let running: String? = {
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index),
                  String(cString: name).hasSuffix("/libBowserSurfaceKit.dylib"),
                  let header = _dyld_get_image_header(index) else { continue }
            let raw = UnsafeRawPointer(header)
            let h = raw.load(as: mach_header_64.self)
            guard h.magic == MH_MAGIC_64, h.sizeofcmds < 1_000_000 else { continue }
            var offset = MemoryLayout<mach_header_64>.size
            for _ in 0..<h.ncmds {
                let command = raw.advanced(by: offset).load(as: load_command.self)
                guard command.cmdsize >= 8, offset + Int(command.cmdsize) <= 32 + Int(h.sizeofcmds) else { break }
                if command.cmd == LC_UUID, command.cmdsize == 24 {
                    return (0..<16).map { String(format: "%02x", raw.load(fromByteOffset: offset + 8 + $0, as: UInt8.self)) }.joined()
                }
                offset += Int(command.cmdsize)
            }
        }
        return nil
    }()
}

private typealias ToolbarEvent = @convention(c) @Sendable (UInt64, UnsafePointer<CChar>) -> Void
private typealias ToolbarABI = @convention(c) () -> Int32
private typealias ToolbarCreate = @convention(c) (UnsafePointer<UInt8>, Int32, UInt64, ToolbarEvent) -> UnsafeMutableRawPointer?
private typealias ToolbarUpdate = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>, Int32) -> Int32
private typealias ToolbarDestroy = @convention(c) (UnsafeMutableRawPointer) -> Void

private func toolbarEvent(_ generation: UInt64, _ text: UnsafePointer<CChar>) {
    let value = String(cString: text)
    // Main-thread button actions complete before any replacement transaction.
    // Do not enqueue them behind a pending update and then discard them as stale.
    if Thread.isMainThread {
        MainActor.assumeIsolated { NativeModuleRuntime.toolbar.deliver(generation, value) }
    } else {
        Task { @MainActor in NativeModuleRuntime.toolbar.deliver(generation, value) }
    }
}

struct NativeModuleFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// All fields are immutable loader results. Only the main-actor slot invokes
/// UI exports. Libraries are retained until process exit, never dlclosed.
final class NativeModuleLibrary: @unchecked Sendable {
    let build: String
    let kind: NativeModuleKind
    let byteCount: Int
    private let handle: UnsafeMutableRawPointer
    fileprivate let create: ToolbarCreate
    fileprivate let update: ToolbarUpdate
    fileprivate let destroy: ToolbarDestroy
    static let identifier = "com.foxwiseai.bowser.command-toolbar"

    static func runningTeam() -> String? {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func validate(_ bundle: URL, team: String?, bundled: Bool, kind: NativeModuleKind = .commandToolbar) throws -> (String, Int) {
        guard bundle.isFileURL, bundle.path == bundle.resolvingSymlinksInPath().path else { throw NativeModuleFailure("module path contains a symlink") }
        let files = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        var total = 0, count = 0
        while let file = files?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw NativeModuleFailure("symlink in module") }
            total += values.fileSize ?? 0; count += 1
            guard total <= 16 * 1024 * 1024, count <= 32 else { throw NativeModuleFailure("module exceeds admission limits") }
        }
        let infoData = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard infoData.count <= 16384,
              let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == kind.identifier,
              info["CFBundleExecutable"] as? String == kind.executable,
              info["BowserHostABI"] as? Int == 1, info["BowserStateSchema"] as? Int == 1,
              info["BowserBackendProtocol"] as? Int == 1,
              let build = info["CFBundleVersion"] as? String,
              build.count == 32, build.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw NativeModuleFailure("incompatible module metadata") }
        if kind == .surfaces {
            guard let running = SurfaceKitIdentity.running, info["BowserSurfaceKit"] as? String == running else {
                throw NativeModuleFailure("surface state library differs; host update required")
            }
        }
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { throw NativeModuleFailure("unsigned module") }
        if let team {
            guard team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), team.count <= 32 else { throw NativeModuleFailure("invalid host signing identity") }
            let rule = "anchor apple generic and identifier \"\(kind.identifier)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
            guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess else { throw NativeModuleFailure("invalid signing requirement") }
        } else if !bundled { throw NativeModuleFailure("live native modules require a Developer ID signed host") }
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else { throw NativeModuleFailure("module signature or Team ID rejected") }
        let executable = bundle.appendingPathComponent("Contents/MacOS/" + kind.executable)
        try validateMachO(Data(contentsOf: executable), allowSurfaceKit: kind == .surfaces)
        return (build, total)
    }

    /// Only system frameworks/libraries and the system Swift runtime may load.
    /// Module packages cannot smuggle a second dependency from a writable path.
    static func validateMachO(_ bytes: Data, allowSurfaceKit: Bool = false) throws {
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= bytes.count else { throw NativeModuleFailure("truncated Mach-O") }
            return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
        }
        guard try u32(0) == 0xfeedfacf, try u32(4) == 0x0100000c else { throw NativeModuleFailure("module must be arm64 Mach-O") }
        let commands = try u32(16), size = try u32(20)
        guard commands <= 512, Int(size) <= bytes.count - 32 else { throw NativeModuleFailure("invalid Mach-O commands") }
        var offset = 32
        for _ in 0..<commands {
            let command = try u32(offset), length = Int(try u32(offset + 4))
            guard length >= 8, offset + length <= 32 + Int(size) else { throw NativeModuleFailure("invalid Mach-O command") }
            if [UInt32(0xc), 0x80000018, 0x8000001f, 0x20, 0x80000023, 0x8000001c].contains(command) {
                let relative = Int(try u32(offset + 8))
                guard relative >= 12, relative < length else { throw NativeModuleFailure("invalid dependency name") }
                let tail = bytes[(offset + relative)..<(offset + length)]
                guard let end = tail.firstIndex(of: 0), let name = String(data: bytes[(offset + relative)..<end], encoding: .utf8) else { throw NativeModuleFailure("invalid dependency string") }
                let allowed = command == 0x8000001c
                    ? name == "/usr/lib/swift"
                    : (name.hasPrefix("/System/Library/") || name.hasPrefix("/usr/lib/") || (name.hasPrefix("@rpath/libswift") && !name.dropFirst(7).contains("/")))
                guard allowed || (allowSurfaceKit && command == 0xc && name == "@rpath/libBowserSurfaceKit.dylib"), !name.contains("..") else { throw NativeModuleFailure("non-system module dependency: \(name)") }
            }
            offset += length
        }
    }

    init(bundle: URL, team: String?, bundled: Bool, kind: NativeModuleKind = .commandToolbar) throws {
        self.kind = kind
        let metadata = try Self.validate(bundle, team: team, bundled: bundled, kind: kind)
        build = metadata.0; byteCount = metadata.1
        guard let handle = dlopen(bundle.appendingPathComponent("Contents/MacOS/" + kind.executable).path, RTLD_NOW | RTLD_LOCAL) else { throw NativeModuleFailure(String(cString: dlerror())) }
        self.handle = handle
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw NativeModuleFailure("missing module export: \(name)") }
            return unsafeBitCast(pointer, to: T.self)
        }
        let abi = try symbol("bowser_toolbar_abi", ToolbarABI.self)
        guard abi() == 1 else { throw NativeModuleFailure("incompatible native ABI") }
        create = try symbol("bowser_toolbar_create", ToolbarCreate.self)
        update = try symbol("bowser_toolbar_update", ToolbarUpdate.self)
        destroy = try symbol("bowser_toolbar_destroy", ToolbarDestroy.self)
    }
}

@MainActor final class NativeModuleSlot: NSView {
    let kind: NativeModuleKind
    private var runtime: NativeModuleRuntime { kind == .surfaces ? .surfaces : .toolbar }
    private var instance: (NativeModuleLibrary, UnsafeMutableRawPointer, UInt64)?
    private var fallback: NSView
    private(set) var snapshot = Data()
    var onAction: ((String) -> Void)?
    var onGenerationChange: ((UInt64) -> Void)?
    var interactionInProgress: (() -> Bool)?
    private(set) var build: String?
    private var rejected = Set<String>()
    init(fallback: NSView, kind: NativeModuleKind = .commandToolbar) {
        self.kind = kind
        self.fallback = fallback
        super.init(frame: .zero)
        mount(fallback)
        (fallback as? BrowserScreenActivating)?.activateScreen()
        runtime.register(self)
    }
    required init?(coder: NSCoder) { fatalError("init(fallback:)") }
    private func mount(_ view: NSView) {
        view.frame = bounds; view.autoresizingMask = [.width, .height]; addSubview(view)
    }
    func setSnapshot(_ data: Data) {
        guard !data.isEmpty, data.count <= 65536 else { return }
        snapshot = data
        if let (library, pointer, _) = instance {
            let accepted = data.withUnsafeBytes { library.update(pointer, $0.bindMemory(to: UInt8.self).baseAddress!, Int32(data.count)) }
            if accepted != 1 { rejected.insert(library.build); retire(); mount(fallback); (fallback as? BrowserScreenActivating)?.activateScreen() }
        }
    }
    var canReplace: Bool {
        guard NSApp != nil, SurfaceServices.shared.presentations == 0, !SurfaceServices.shared.hasInteractions, interactionInProgress?() != true, !snapshot.isEmpty, NSEvent.pressedMouseButtons == 0, NSApp.modalWindow == nil,
              window?.attachedSheet == nil, window?.parent?.attachedSheet == nil, window?.inLiveResize != true, window?.parent?.inLiveResize != true,
              (window?.firstResponder as? NSTextView)?.isFieldEditor != true,
              (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
        return true
    }
    @discardableResult func install(_ library: NativeModuleLibrary) -> Bool {
        guard library.kind == kind, canReplace, build != library.build, !rejected.contains(library.build) else { return false }
        rejected.insert(library.build)
        let generation = runtime.newGeneration()
        let responder = window?.firstResponder as? NSView
        let retainedResponder = responder?.isDescendant(of: self) == true ? responder : nil
        let start = ProcessInfo.processInfo.systemUptime
        guard let pointer = snapshot.withUnsafeBytes({ library.create($0.bindMemory(to: UInt8.self).baseAddress!, Int32(snapshot.count), generation, toolbarEvent) }) else { return false }
        let view = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
        guard view.superview == nil, view.window == nil,
              (ProcessInfo.processInfo.systemUptime - start) < 0.016 else { library.destroy(pointer); return false }
        // No events interleave this main-actor transaction. The host owns all
        // state, so preparation and rollback cannot lose a browser action.
        mount(view)
        view.layoutSubtreeIfNeeded()
        let healthy = snapshot.withUnsafeBytes { library.update(pointer, $0.bindMemory(to: UInt8.self).baseAddress!, Int32(snapshot.count)) } == 1
        guard healthy else { library.destroy(pointer); return false }
        retire(); fallback.removeFromSuperview()
        instance = (library, pointer, generation); build = library.build
        rejected.remove(library.build)
        runtime.authorize(generation, slot: self)
        (view as? BrowserScreenActivating)?.activateScreen()
        onGenerationChange?(generation)
        view.layoutSubtreeIfNeeded()
        if let retainedResponder, retainedResponder.isDescendant(of: self) {
            window?.makeFirstResponder(retainedResponder)
        }
        return true
    }
    func retire() {
        if let (library, pointer, generation) = instance {
            runtime.revoke(generation)
            runtime.trackRetirement(Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue())
            library.destroy(pointer)
        }
        instance = nil; build = nil
        onGenerationChange?(0)
    }
}

@MainActor final class NativeModuleRuntime {
    static let toolbar = NativeModuleRuntime(kind: .commandToolbar)
    static let surfaces = NativeModuleRuntime(kind: .surfaces)
    private let kind: NativeModuleKind
    private init(kind: NativeModuleKind) { self.kind = kind }
    private let slots = NSHashTable<NativeModuleSlot>.weakObjects()
    private var authorities: [UInt64: WeakToolbarSlot] = [:]
    private static var generation: UInt64 = 0
    private var libraries: [NativeModuleLibrary] = []
    private var candidate: NativeModuleLibrary?
    private var loading = false
    private(set) var lastError: String?
    private var retiredViews: [WeakToolbarView] = []
    private struct WeakToolbarView { weak var value: NSView? }
    func trackRetirement(_ view: NSView) { retiredViews.append(WeakToolbarView(value: view)) }
    private var seen = Set<String>()
    private var timer: Timer?
    private var menuTracking = false
    private var transitions = Set<Int>()
    private let queue = DispatchQueue(label: "bowser.native-toolbar-loader", qos: .utility)
    private var observers: [NSObjectProtocol] = []
    private let team = NativeModuleLibrary.runningTeam()
    private struct WeakToolbarSlot { weak var value: NativeModuleSlot? }
    func clearTransition(_ window: NSWindow) { transitions.remove(window.windowNumber) }
    func newGeneration() -> UInt64 { Self.generation += 1; return Self.generation }
    func authorize(_ generation: UInt64, slot: NativeModuleSlot) { authorities[generation] = WeakToolbarSlot(value: slot) }
    func revoke(_ generation: UInt64) { authorities.removeValue(forKey: generation) }
    func deliver(_ generation: UInt64, _ event: String) { (Self.toolbar.authorities[generation]?.value ?? Self.surfaces.authorities[generation]?.value)?.onAction?(event) }
    func register(_ slot: NativeModuleSlot) {
        slots.add(slot)
        if timer == nil {
            for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                    let tracking = notification.name == NSMenu.didBeginTrackingNotification
                    MainActor.assumeIsolated { self.menuTracking = tracking }
                })
            }
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                    let window = notification.object as? NSWindow
                    let starting = [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification].contains(notification.name)
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        if starting { self.transitions.insert(window.windowNumber) }
                        else { self.transitions.remove(window.windowNumber) }
                    }
                })
            }
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in self.poll() } }
            poll()
        }
    }
    private func poll() {
        retiredViews.removeAll { $0.value == nil }
        if retiredViews.isEmpty, !menuTracking, transitions.isEmpty, let candidate {
            for slot in slots.allObjects where slot.build != candidate.build { _ = slot.install(candidate) }
        }
        retiredViews.removeAll { $0.value == nil }
        guard retiredViews.isEmpty, !loading, seen.count < 32, libraries.reduce(0, { $0 + $1.byteCount }) < 64 * 1024 * 1024 else { return }
        let root = BowserPaths.home.resolvingSymlinksInPath().appendingPathComponent("native-modules/" + kind.rawValue)
        var url = Bundle.main.url(forResource: kind.executable, withExtension: "bundle").map { $0.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent($0.lastPathComponent) }
        var bundled = true
        if let data = try? Data(contentsOf: root.appendingPathComponent("current")), data.count <= 64,
           let id = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           id.count == 32, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), team != nil {
            url = root.appendingPathComponent(id + ".bundle"); bundled = false
        }
        guard let url, !seen.contains(url.path) else { return }
        seen.insert(url.path); loading = true
        let team = team, isBundled = bundled, kind = kind
        let remainingBytes = 64 * 1024 * 1024 - libraries.reduce(0, { $0 + $1.byteCount })
        queue.async {
            let result = Result { () throws -> NativeModuleLibrary in
                // Private per-process immutable copy avoids loading a publisher's
                // mutable staging path. Revalidate the copy before executing it.
                let metadata = try NativeModuleLibrary.validate(url, team: team, bundled: isBundled, kind: kind)
                guard metadata.1 <= remainingBytes else { throw NativeModuleFailure("native module byte budget exhausted; quit normally to activate") }
                let staging = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("bowser-toolbar-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let copy = staging.appendingPathComponent(kind.executable + ".bundle")
                try FileManager.default.copyItem(at: url, to: copy)
                if let entries = FileManager.default.enumerator(at: copy, includingPropertiesForKeys: [.isDirectoryKey]) {
                    for case let entry as URL in entries {
                        let directory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                        try FileManager.default.setAttributes([.posixPermissions: directory ? 0o500 : 0o400], ofItemAtPath: entry.path)
                    }
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: copy.path)
                let result = try NativeModuleLibrary(bundle: copy, team: team, bundled: isBundled, kind: kind)
                return result
            }
            Task { @MainActor in
                self.loading = false
                switch result {
                case .success(let library): self.libraries.append(library); self.candidate = library; self.lastError = nil
                case .failure(let error): self.lastError = String(describing: error); NSLog("Native module update rejected: %@", String(describing: error))
                }
            }
        }
    }
}
