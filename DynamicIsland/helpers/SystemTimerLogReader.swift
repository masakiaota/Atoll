/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Darwin
import Foundation

/// Read on the consumer's serial queue, so a slow parser leaves bytes in the
/// bounded OS pipe instead of enqueueing an unbounded number of Data objects.
final class SystemTimerLogReader {
    static let readSize = 64 * 1024

    private let source: DispatchSourceRead
    private let descriptor: Int32
    private let onData: (Data) -> Void
    private let onFailure: (Int32) -> Void

    init(handle: FileHandle, queue: DispatchQueue,
         onData: @escaping (Data) -> Void,
         onFailure: @escaping (Int32) -> Void) throws {
        descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        self.onData = onData
        self.onFailure = onFailure
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            autoreleasepool { _ = self?.readAvailableData() }
        }
        // A source must finish using the descriptor before it can be closed or
        // reused by another stream. Capture this handle, not the bridge's next one.
        source.setCancelHandler { try? handle.close() }
        source.resume()
    }

    deinit { source.cancel() }

    func cancel() { source.cancel() }

    /// The producer has exited. Deliver its final buffered events before closing.
    /// Call on the reader's queue, after process termination has been confirmed.
    func finish() {
        while autoreleasepool(invoking: { readAvailableData() }) {}
        source.cancel()
    }

    private func readAvailableData() -> Bool {
        guard !source.isCancelled else { return false }
        var bytes = [UInt8](repeating: 0, count: Self.readSize)
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        }
        if count > 0 {
            onData(Data(bytes.prefix(count)))
            return true
        } else if count == 0 {
            source.cancel()
        } else {
            let error = errno
            if error == EINTR { return true }
            guard error != EAGAIN else { return false }
            source.cancel()
            onFailure(error)
        }
        return false
    }
}

/// Keep only one incomplete line. An oversized line is discarded through its
/// newline, preventing a suffix from being interpreted as a separate JSON event.
struct SystemTimerLogLineBuffer {
    let maximumLineBytes: Int
    var bufferedByteCount: Int { buffer.count }
    private var buffer = Data()
    private var discardingLine = false

    init(maximumLineBytes: Int = 1_048_576) {
        precondition(maximumLineBytes > 0)
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func reset() {
        buffer = Data()
        discardingLine = false
    }

    mutating func append(_ data: Data, onLine: (Data) -> Void) {
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            if !discardingLine {
                let count = data.distance(from: start, to: end)
                if count > maximumLineBytes - buffer.count {
                    buffer = Data()
                    discardingLine = true
                } else {
                    buffer.append(contentsOf: data[start..<end])
                }
            }
            guard let newline else { return }
            if !discardingLine, !buffer.isEmpty { onLine(buffer) }
            buffer = Data()
            discardingLine = false
            start = data.index(after: newline)
        }
    }
}
