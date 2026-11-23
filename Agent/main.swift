import Foundation
import NotchedCore

// notched-agent hook <tool>
//
// Run by an agent's hook with the hook's JSON on stdin. Writes the session's record into the inbox
// with an atomic rename, and never blocks on Notched. It always exits 0 and prints nothing, so a
// broken install or a missing inbox can never slow an agent down or fail its turn.

let arguments = CommandLine.arguments
guard arguments.count == 3, arguments[1] == "hook", let tool = AgentTool(rawValue: arguments[2]) else { exit(0) }

let payload = FileHandle.standardInput.readDataToEndOfFile()
guard let input = try? JSONDecoder().decode(HookInput.self, from: payload),
      let name = AgentRecord.fileName(tool: tool, session: input.sessionID) else { exit(0) }

let environment = ProcessInfo.processInfo.environment
let inbox = AgentInboxPath.directory(environment: environment, home: FileManager.default.homeDirectoryForCurrentUser)
let file = inbox.appendingPathComponent(name)
let previous = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(AgentRecord.self, from: $0) }
let agent = AgentProcess.agent(above: getppid())
let context = HookContext(tool: tool, pid: agent?.pid, pidStart: agent?.start, host: environment["__CFBundleIdentifier"])

guard let record = HookMapping.next(input, previous: previous, context: context,
                                    wallNow: Date().timeIntervalSince1970),
      let data = try? JSONEncoder().encode(record) else { exit(0) }

let manager = FileManager.default
try? manager.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
// A dot file, so the app's scan never reads a half-written record.
let temporary = inbox.appendingPathComponent(".\(name).\(getpid()).tmp")
if manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) {
    if rename(temporary.path, file.path) != 0 { unlink(temporary.path) }
}
exit(0)
