import AppKit
import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }
}

/// Run a program without a shell. Output is read concurrently so large output can't deadlock.
public enum Shell {
    public static func run(
        _ executable: String,
        _ args: [String] = [],
        env: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval = 10
    ) async -> ShellResult {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            if let env {
                p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
            }
            let out = Pipe(), err = Pipe(), inp = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = stdin == nil ? FileHandle.nullDevice : inp

            let lock = NSLock()
            var outData = Data(), errData = Data()
            var timedOut = false
            do {
                try p.run()
            } catch {
                cont.resume(returning: ShellResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false))
                return
            }
            // Readers start only once the child holds the write ends, so a failed launch can't strand them.
            let group = DispatchGroup()
            for (pipe, isOut) in [(out, true), (err, false)] {
                group.enter()
                DispatchQueue.global().async {
                    let d = pipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock()
                    if isOut { outData = d } else { errData = d }
                    lock.unlock()
                    group.leave()
                }
            }
            if let stdin {
                DispatchQueue.global().async {
                    inp.fileHandleForWriting.write(stdin)
                    try? inp.fileHandleForWriting.close()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning {
                    lock.lock(); timedOut = true; lock.unlock()
                    p.terminate()
                }
            }
            DispatchQueue.global().async {
                p.waitUntilExit()
                group.wait()
                lock.lock()
                let r = ShellResult(
                    status: p.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self),
                    timedOut: timedOut)
                lock.unlock()
                cont.resume(returning: r)
            }
        }
    }

    /// Run AppleScript source via osascript.
    public static func appleScript(_ source: String, timeout: TimeInterval = 5) async -> ShellResult {
        await run("/usr/bin/osascript", ["-e", source], timeout: timeout)
    }
}

/// Small helpers for opening URLs and the clipboard (main-thread safe).
public enum SystemActions {
    @discardableResult
    public static func open(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }

    public static func copyToClipboard(_ text: String) async {
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }
}
