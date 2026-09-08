import Foundation
import Darwin
import BackendRuntime

@main struct BackendMain {
    @MainActor static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "--control" {
                guard args.count >= 3 else { throw RuntimeFailure("usage: backend-host --control HOME OP [RUNTIME]") }
                var message: Message = ["op": args[2]]
                if args.count > 3 { message["runtime"] = args[3] }
                let reply = try await request(child(URL(fileURLWithPath: args[1]), "backend/host.sock"), message, timeout: 30)
                print(String(decoding: try encode(reply), as: UTF8.self))
            } else {
                guard args.count == 2 else { throw RuntimeFailure("usage: backend-host HOME RUNTIME") }
                try await Host(URL(fileURLWithPath: args[0]), URL(fileURLWithPath: args[1])).run()
            }
        } catch { fputs("backend-host: \(error)\n", stderr); exit(1) }
    }
}
