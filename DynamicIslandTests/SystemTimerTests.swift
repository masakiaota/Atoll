import Combine
import Darwin
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private func wait(_ semaphore: DispatchSemaphore, _ message: String) {
    expect(semaphore.wait(timeout: .now() + 5) == .success, message)
}

private func expectClosed(_ descriptor: Int32) {
    let deadline = Date().addingTimeInterval(3)
    while fcntl(descriptor, F_GETFD) != -1, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    expect(fcntl(descriptor, F_GETFD) == -1 && errno == EBADF, "Reader must close its descriptor")
}

private final class Capture {
    var chunks: [Data] = []
}

// Surrounding services are inert. The bridge's actual initialization, read,
// start/stop/restart and file-monitor methods are inserted by the runner.
private enum Defaults {
    struct Key {
        let defaultValue: Bool
        static let mirrorSystemTimer = Key(defaultValue: DEFAULT_MIRROR_SYSTEM_TIMER)
    }
    struct Change { let newValue: Bool }
    static var savedValue: Bool?
    static let changes = PassthroughSubject<Change, Never>()
    static subscript(key: Key) -> Bool {
        get { savedValue ?? key.defaultValue }
        set { savedValue = newValue; changes.send(Change(newValue: newValue)) }
    }
    static func publisher(_ key: Key, options: [String]) -> AnyPublisher<Change, Never> {
        changes.eraseToAnyPublisher()
    }
}

private final class Process {
    var executableURL: URL?
    var arguments: [String]?
    var standardOutput: Any?
    var standardError: Any?
    var terminationHandler: ((Process) -> Void)?
    var isRunning = false
    let processIdentifier: Int32 = 123
    static var launches = 0
    static var failNextLaunch = false
    func run() throws {
        if Self.failNextLaunch {
            Self.failNextLaunch = false
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        isRunning = true
        Self.launches += 1
    }
    func terminate() { isRunning = false }
    func waitUntilExit() { preconditionFailure("Stop must not block the reader's cancellation queue") }
}

private final class TimerManager {
    static let shared = TimerManager()
    func endExternalTimer(triggerSmoothClose: Bool) {}
}

private func AXIsProcessTrusted() -> Bool { false }
private typealias AXUIElement = Int

private final class Bridge {
    typealias TimerMetadata = Int
    typealias PendingMainUpdate = Int
    let preferencesPath: String = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! Data().write(to: url)
        return url.path
    }()
    var lines: [Data] = []
    var isMonitoring: Bool { logProcess != nil || ticker != nil || fileMonitor != nil }
    func refreshMetadata() {}
    func pollMenuExtra() {}
    func postAccessibilityWarningIfNeeded() {}
    func processLogLine(_ data: Data) { lines.append(data) }
    func logDebug(_ text: String) {}
    func logInfo(_ text: String) {}
    func logError(_ text: String) {}
    deinit { try? FileManager.default.removeItem(atPath: preferencesPath) }
    // TIMER_BRIDGE_METHODS
}

@main
private struct SystemTimerTests {
    static func main() throws {
        testLineFraming()
        try testSlowConsumer()
        try testEOFAndFinalData()
        try testReaderDeinit()
        try testRealProcess()
        testBridgeLifecycle()
    }

    static func testLineFraming() {
        var buffer = SystemTimerLogLineBuffer(maximumLineBytes: 16)
        var lines: [Data] = []
        let text = Data("日本語\nsecond\n\n".utf8)
        for byte in text { buffer.append(Data([byte])) { lines.append($0) } }
        expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["日本語", "second"], "Fragmented UTF-8 and empty lines")
        expect(buffer.bufferedByteCount == 0, "Completed lines must not be retained")

        lines = []
        buffer.append(Data(repeating: 65, count: 16)) { lines.append($0) }
        expect(buffer.bufferedByteCount == 16, "An exact-limit line is accepted")
        buffer.append(Data([10])) { lines.append($0) }
        expect(lines == [Data(repeating: 65, count: 16)], "An exact-limit line must be delivered")

        lines = []
        for _ in 0..<1000 {
            buffer.append(Data(repeating: 65, count: 32)) { lines.append($0) }
            expect(buffer.bufferedByteCount <= 16, "Oversized fragmented input must stay bounded")
        }
        buffer.append(Data("{\"suffix\":1}\n{\"next\":2}\n".utf8)) { lines.append($0) }
        expect(lines == [Data("{\"next\":2}".utf8)], "Discard the oversized line through its newline, then recover")

        lines = []
        buffer.append(Data(String(repeating: "ok\n", count: 1000).utf8)) { lines.append($0) }
        expect(lines.count == 1000, "Many small lines must not be discarded as one oversized buffer")
        buffer.append(Data("unfinished".utf8)) { _ in }
        buffer.reset()
        buffer.append(Data("fresh\n".utf8)) { lines.append($0) }
        expect(lines.last == Data("fresh".utf8), "Restart must not splice in the previous stream")
    }

    static func testSlowConsumer() throws {
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let queue = DispatchQueue(label: "test.timer.slow")
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let capture = Capture()
        let reader = try SystemTimerLogReader(handle: pipe.fileHandleForReading, queue: queue, onData: { data in
            dispatchPrecondition(condition: .onQueue(queue))
            capture.chunks.append(data)
            entered.signal()
            wait(resume, "Consumer must be released")
        }, onFailure: { _ in preconditionFailure("Unexpected read error") })
        try pipe.fileHandleForWriting.write(contentsOf: Data("start\n".utf8))
        wait(entered, "Reader must deliver the first chunk")

        let writer = pipe.fileHandleForWriting.fileDescriptor
        expect(fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK) != -1, "Nonblocking test writer")
        let bytes = [UInt8](repeating: 65, count: SystemTimerLogReader.readSize)
        var blocked = false
        for _ in 0..<256 {
            let written = bytes.withUnsafeBytes { Darwin.write(writer, $0.baseAddress, $0.count) }
            if written == -1, errno == EAGAIN { blocked = true; break }
            expect(written > 0, "Unexpected writer failure")
        }
        expect(blocked, "A slow consumer must stop reads instead of accumulating queued Data")
        reader.cancel()
        expect(fcntl(descriptor, F_GETFD) != -1, "Do not close the descriptor while a handler is executing")
        resume.signal()
        expectClosed(descriptor)
        queue.sync {
            expect(capture.chunks.count == 1, "Cancellation must discard unread data")
            expect(capture.chunks.allSatisfy { $0.count <= SystemTimerLogReader.readSize }, "Read chunks must be bounded")
        }
        try pipe.fileHandleForWriting.close()
    }

    static func testEOFAndFinalData() throws {
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let queue = DispatchQueue(label: "test.timer.eof")
        let capture = Capture()
        var reader: SystemTimerLogReader!
        // Hold the queue so termination can be handled before a read event.
        try queue.sync {
            reader = try SystemTimerLogReader(handle: pipe.fileHandleForReading, queue: queue,
                onData: { capture.chunks.append($0) }, onFailure: { _ in preconditionFailure("Unexpected read error") })
            try pipe.fileHandleForWriting.write(contentsOf: Data("final event\n".utf8))
            try pipe.fileHandleForWriting.close()
            reader.finish()
            expect(capture.chunks.reduce(Data(), +) == Data("final event\n".utf8), "Deliver buffered events when producer exits before the read callback")
        }
        expectClosed(descriptor)
        withExtendedLifetime(reader) {}

        let emptyPipe = Pipe()
        let emptyDescriptor = emptyPipe.fileHandleForReading.fileDescriptor
        let emptyReader = try SystemTimerLogReader(handle: emptyPipe.fileHandleForReading, queue: queue,
            onData: { _ in preconditionFailure("Empty EOF must not deliver data") },
            onFailure: { _ in preconditionFailure("EOF is not a read error") })
        try emptyPipe.fileHandleForWriting.close()
        expectClosed(emptyDescriptor)
        withExtendedLifetime(emptyReader) {}
    }

    static func testReaderDeinit() throws {
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var reader: SystemTimerLogReader? = try SystemTimerLogReader(
            handle: pipe.fileHandleForReading, queue: DispatchQueue(label: "test.timer.deinit"),
            onData: { _ in }, onFailure: { _ in })
        weak var weakReader = reader
        reader = nil
        expect(weakReader == nil, "Read source must not retain the reader")
        expectClosed(descriptor)
        try pipe.fileHandleForWriting.close()
    }

    static func testRealProcess() throws {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
        let text = String(repeating: "timer event\n", count: 12_000)
        process.arguments = ["%s", text]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let queue = DispatchQueue(label: "test.timer.process")
        let capture = Capture()
        let done = DispatchSemaphore(value: 0)
        let reader = try SystemTimerLogReader(handle: pipe.fileHandleForReading, queue: queue,
            onData: { capture.chunks.append($0) }, onFailure: { _ in preconditionFailure("Unexpected read error") })
        process.terminationHandler = { _ in
            queue.async {
                reader.finish()
                done.signal()
            }
        }
        try process.run()
        wait(done, "A real child process must exit without a pipe deadlock")
        queue.sync {
            expect(capture.chunks.reduce(Data(), +) == Data(text.utf8), "Real process output must arrive without gaps or duplication")
            expect(capture.chunks.count > 1, "The output must span multiple reads")
            expect(capture.chunks.allSatisfy { $0.count <= SystemTimerLogReader.readSize }, "Every read must stay within 64 KiB")
        }
        expectClosed(descriptor)
        expect(process.terminationStatus == 0, "The child process must succeed")
    }

    static func testBridgeLifecycle() {
        Defaults.savedValue = nil
        let bridge = Bridge()
        bridge.queue.sync {
            expect(!bridge.isMonitoring && Process.launches == 0, "Unset preference must not launch any monitoring")
        }
        Defaults[.mirrorSystemTimer] = true
        bridge.queue.sync {
            expect(Process.launches == 1 && bridge.logReader != nil, "Explicit opt-in starts the stream")
        }
        bridge.startIfNeeded()
        bridge.queue.sync { expect(Process.launches == 1, "Repeated enable must not duplicate streams") }
        let descriptors = bridge.queue.sync { () -> (Int32, Int32) in
            let previous = bridge.fileMonitor!
            let previousDescriptor = previous.handle
            previous.cancel()
            bridge.fileMonitor = nil
            bridge.startFileMonitor()
            return (previousDescriptor, bridge.fileMonitor!.handle)
        }
        expectClosed(descriptors.0)
        expect(fcntl(descriptors.1, F_GETFD) != -1, "Old file-monitor cancellation must not close the replacement descriptor")
        let old = bridge.queue.sync { bridge.logProcess! }
        Defaults[.mirrorSystemTimer] = false
        bridge.queue.sync {
            expect(!bridge.isMonitoring && bridge.logReader == nil, "Disabling must release monitoring resources")
            expect(!old.isRunning, "Disabling must terminate the child process")
            expect(bridge.logBuffer.bufferedByteCount == 0, "Disabling must release buffered data")
            bridge.scheduleLogStreamRestart()
            expect(bridge.logRestartWorkItem == nil, "Disabled monitoring must not schedule a restart")
        }
        Defaults[.mirrorSystemTimer] = true
        bridge.queue.sync {
            let current = bridge.logProcess!
            bridge.handleLogStreamTermination(old)
            expect(bridge.logProcess === current && bridge.logReader != nil, "Old termination must not clear a replacement stream")
            // Reproduce the termination/read ordering with the bridge's real callbacks.
            let pipe = current.standardOutput as! Pipe
            try! pipe.fileHandleForWriting.write(contentsOf: Data("final timer event\n".utf8))
            try! pipe.fileHandleForWriting.close()
            current.terminate()
            bridge.handleLogStreamTermination(current)
            expect(bridge.lines.last == Data("final timer event".utf8), "A final event must reach the parser before cleanup")
            expect(bridge.logReader == nil && bridge.logRestartWorkItem != nil, "Unexpected exit schedules recovery")
        }
        Defaults[.mirrorSystemTimer] = false
        bridge.queue.sync { expect(bridge.logRestartWorkItem == nil, "Disabling cancels scheduled recovery") }

        // Both settings changes happen before the queued start executes.
        bridge.queue.sync {
            Defaults[.mirrorSystemTimer] = true
            Defaults[.mirrorSystemTimer] = false
        }
        bridge.queue.sync { expect(Process.launches == 2, "A stale queued enable must not start after disable") }

        Process.failNextLaunch = true
        Defaults[.mirrorSystemTimer] = true
        bridge.queue.sync {
            expect(bridge.logProcess == nil && bridge.logReader == nil, "Failed launch must release its reader")
        }
        Defaults[.mirrorSystemTimer] = false
        bridge.queue.sync { expect(!bridge.isMonitoring, "Disable after launch failure must clean up the file monitor") }

        Defaults.savedValue = true
        let saved = Bridge()
        saved.queue.sync { expect(saved.logProcess != nil, "Persisted explicit opt-in must keep working") }
        saved.stopMonitoring(clearTimer: false)
        saved.queue.sync {}
        Defaults.savedValue = false
    }
}
