import Foundation
import Darwin

public typealias Message = [String: Any]
public struct RuntimeFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
public func json(_ data: Data) throws -> Message {
    guard let result = try JSONSerialization.jsonObject(with: data) as? Message else { throw RuntimeFailure("expected JSON object") }
    return result
}
public func encode(_ message: Message) throws -> Data { try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) }
public func atomicJSON(_ path: URL, _ message: Message) throws {
    let temporary = path.appendingPathExtension("new")
    try encode(message).write(to: temporary)
    let fd = Darwin.open(temporary.path, O_RDONLY)
    guard fd >= 0 else { throw RuntimeFailure("cannot open checkpoint") }
    let result = fsync(fd); Darwin.close(fd)
    guard result == 0, rename(temporary.path, path.path) == 0 else { throw RuntimeFailure("cannot persist checkpoint") }
}
public func readJSON(_ path: URL) throws -> Message { try json(Data(contentsOf: path)) }
public func exists(_ path: URL) -> Bool { FileManager.default.fileExists(atPath: path.path) }
public func remove(_ path: URL) throws { if exists(path) { try FileManager.default.removeItem(at: path) } }
public func mkdir(_ path: URL) throws { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
public func child(_ path: URL, _ name: String) -> URL { path.appendingPathComponent(name) }
public func until(_ timeout: Double = 10, _ predicate: () -> Bool) async throws {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while !predicate() {
        try Task.checkCancellation()
        if ProcessInfo.processInfo.systemUptime >= end { throw RuntimeFailure("backend readiness timed out") }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
public final class FileLock {
    private let fd: Int32
    public init(_ path: URL, nonblocking: Bool = false) throws {
        fd = Darwin.open(path.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw RuntimeFailure("cannot open lock: \(path.path)") }
        guard flock(fd, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
            Darwin.close(fd); throw RuntimeFailure("lock already held: \(path.path)")
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
}
private func address(_ path: String) throws -> sockaddr_un {
    var value = sockaddr_un()
    value.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw RuntimeFailure("Unix socket path too long") }
    value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: bytes) }
    return value
}
public final class Peer: @unchecked Sendable {
    public let messages: AsyncThrowingStream<Message, Error>
    private let continuation: AsyncThrowingStream<Message, Error>.Continuation
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    private let writes = DispatchQueue(label: "bowser.relay.writes")
    public init(fd: Int32) {
        self.fd = fd
        var output: AsyncThrowingStream<Message, Error>.Continuation!
        messages = AsyncThrowingStream { output = $0 }
        continuation = output
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        DispatchQueue.global().async { self.readLoop() }
    }
    public static func connect(_ path: URL) throws -> Peer {
        var addr = try address(path.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RuntimeFailure("socket failed") }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw RuntimeFailure("cannot connect to \(path.lastPathComponent)") }
        return Peer(fd: fd)
    }
    private func readExact(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw RuntimeFailure("connection closed") }
                offset += n
            }
        }
        return data
    }
    private func readLoop() {
        defer {
            lock.lock(); stopped = true; Darwin.close(fd); lock.unlock()
        }
        do {
            while true {
                let header = try readExact(4)
                let count = header.reduce(0) { ($0 << 8) | Int($1) }
                guard count <= 64 * 1024 * 1024 else { throw RuntimeFailure("frame exceeds limit") }
                continuation.yield(try json(readExact(count)))
            }
        } catch { continuation.finish(throwing: error) }
    }
    /// Enqueue synchronously: replay cannot be overtaken by newer native events.
    public func send(_ message: Message) throws {
        let data = try encode(message)
        guard data.count <= 64 * 1024 * 1024 else { throw RuntimeFailure("frame exceeds limit") }
        var size = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }; frame.append(data)
        writes.async {
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.stopped else { return }
            frame.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(self.fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { self.stopped = true; shutdown(self.fd, SHUT_RDWR); break }
                    offset += n
                }
            }
        }
    }
    public func close() {
        lock.lock(); defer { lock.unlock() }
        if !stopped { stopped = true; shutdown(fd, SHUT_RDWR) }
    }
    public func finishWrites() async { await withCheckedContinuation { continuation in writes.async { continuation.resume() } } }
}
public final class Listener: @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceRead
    private let path: URL
    public init(_ path: URL, accept: @escaping (Peer) -> Void) throws {
        self.path = path
        var addr = try address(path.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        self.fd = fd
        guard fd >= 0 else { throw RuntimeFailure("socket failed") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, listen(fd, 16) == 0 else { Darwin.close(fd); throw RuntimeFailure("cannot listen: \(path.path)") }
        chmod(path.path, 0o600)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "bowser.relay.accept"))
        let descriptor = fd
        source.setEventHandler {
            while true {
                let client = Darwin.accept(descriptor, nil, nil)
                if client < 0 { break }
                _ = fcntl(client, F_SETFL, 0)
                accept(Peer(fd: client))
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }
    public func close() { source.cancel(); unlink(path.path) }
    deinit { close() }
}
public func request(_ path: URL, _ message: Message, timeout: Double = 1) async throws -> Message {
    let peer = try Peer.connect(path)
    defer { peer.close() }
    let deadline = Task { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); peer.close() }
    defer { deadline.cancel() }
    try peer.send(message)
    var iterator = peer.messages.makeAsyncIterator()
    guard let reply = try await iterator.next() else { throw RuntimeFailure("empty reply") }
    guard reply["ok"] as? Bool == true else { throw RuntimeFailure(reply["error"] as? String ?? "backend refused") }
    return reply
}

/// The agent endpoint uses newline JSON instead of the native framed protocol.
public func lineRequest(_ path: URL, _ message: Message) throws -> Message {
    var addr = try address(path.path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RuntimeFailure("socket failed") }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 30, tv_usec: 0), one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    let status = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard status == 0 else { throw RuntimeFailure("agent.sock unreachable") }
    var data = try encode(message); data.append(10)
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw RuntimeFailure("agent request failed") }; offset += n
        }
    }
    var reply = Data(), buffer = [UInt8](repeating: 0, count: 65536)
    while reply.last != 10 {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw RuntimeFailure("agent response disconnected or timed out") }
        reply.append(contentsOf: buffer.prefix(count))
        guard reply.count <= 64 * 1024 * 1024 else { throw RuntimeFailure("agent response exceeds limit") }
    }
    return try json(reply)
}
