import Foundation
import Darwin
import BackendRuntime

@main struct RuntimeMain {
    static func main() async {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            var mode = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
            if mode == "BowserRuntimeTool" {
                guard !args.isEmpty else { throw RuntimeFailure("expected runtime tool command") }
                mode = args.removeFirst()
            }
            switch mode {
            case "detach": try detach(args)
            case "bowser-mcp-bridge": try runMCP()
            case "apply-update": try await runUpdater(args)
            case "publish":
                guard args.count == 6 else { throw RuntimeFailure("publish PENDING STAGE RUNTIME BUNDLE SHELL_ONLY BRAIN_ONLY") }
                let pending = URL(fileURLWithPath: args[0])
                try publish(pending, ["stage": args[1], "runtime": args[2], "bundle": args[3], "home": pending.deletingLastPathComponent().deletingLastPathComponent().path], shellOnly: args[4] == "1", brainOnly: args[5] == "1")
            case "active-runtime":
                guard args.count == 1, let runtime = try readJSON(URL(fileURLWithPath: args[0]))["runtime"] as? String else { throw RuntimeFailure("invalid runtime pointer") }
                print(runtime)
            case "watcher-plist":
                guard args.count == 2 else { throw RuntimeFailure("watcher-plist PATH UPDATE_ROOT") }
                let root = args[1]
                let plist: Message = ["Label": "com.foxwiseai.bowser.pending-update", "ProgramArguments": [root + "/apply-update", root + "/pending.json", "--wait"], "RunAtLoad": true, "KeepAlive": ["PathState": [root + "/pending.json": true]], "ThrottleInterval": 10, "StandardOutPath": root + "/install.log", "StandardErrorPath": root + "/install.log"]
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: args[0]), options: .atomic)
            default: throw RuntimeFailure("unknown runtime tool: \(mode)")
            }
        } catch { fputs("bowser runtime: \(error)\n", stderr); exit(1) }
    }
}
