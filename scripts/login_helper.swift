import Darwin
import Foundation

var pathBuffer = [CChar](repeating: 0, count: 4096)
let pathLength = proc_pidpath(getpid(), &pathBuffer, UInt32(pathBuffer.count))
guard pathLength > 0 else {
    fputs("BookooHydration login helper could not resolve its executable path\n", stderr)
    exit(1)
}

let executableURL = URL(fileURLWithPath: String(cString: pathBuffer)).resolvingSymlinksInPath()
let appURL = executableURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
process.arguments = ["-g", appURL.path]
do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    fputs("BookooHydration login helper failed: \\(error)\n", stderr)
    exit(1)
}
