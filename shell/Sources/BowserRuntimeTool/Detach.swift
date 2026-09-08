import Foundation
import Darwin
import BackendRuntime

func detach(_ args: [String]) throws {
    guard let log = args.first, let separator = args.firstIndex(of: "--"), separator + 1 < args.count else {
        throw RuntimeFailure("usage: detach LOG [VAR=value ...] -- COMMAND [ARGS]")
    }
    var env = ProcessInfo.processInfo.environment
    for value in args[1..<separator] {
        guard let index = value.firstIndex(of: "=") else { throw RuntimeFailure("invalid environment assignment") }
        env[String(value[..<index])] = String(value[value.index(after: index)...])
    }
    let command = Array(args[(separator + 1)...])
    let argv = command.map { strdup($0) } + [nil]
    let envp = env.map { strdup($0.key + "=" + $0.value) } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var pid: pid_t = 0
    let result = posix_spawnp(&pid, command[0], &actions, &attributes, argv, envp)
    guard result == 0 else { throw RuntimeFailure("cannot launch \(command[0]): \(String(cString: strerror(result)))") }
    print(pid)
}
