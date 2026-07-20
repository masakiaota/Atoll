/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import CryptoKit
import Darwin
import Defaults
import Foundation

/// Fail-closed validation for the bundled, opaque MediaRemote components.
///
/// Validation is intentionally repeated immediately before every launch. The
/// result must not be cached because the files can change while Atoll is open.
enum MediaRemoteExecutionPolicy {
    private final class RuntimeBlockState: @unchecked Sendable {
        private let lock = NSLock()
        private var isBlocked = false

        func read() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return isBlocked
        }

        func set(_ blocked: Bool) {
            lock.lock()
            isBlocked = blocked
            lock.unlock()
        }
    }

    private static let runtimeBlockState = RuntimeBlockState()

    struct Installation {
        let scriptURL: URL
        let frameworkURL: URL
        let frameworkExecutableURL: URL
    }

    struct PreparedExecution {
        let installation: Installation
        let scriptSource: String
        let frameworkExecutableHandle: FileHandle
    }

    enum ValidationError: LocalizedError {
        case consentRequired
        case missingResource(String)
        case invalidResource(String)
        case unreadableResource(String, String)
        case hashMismatch(String)

        var errorDescription: String? {
            switch self {
            case .consentRequired:
                return "Bundled MediaRemote execution has not been enabled by the user."
            case .missingResource(let name):
                return "The bundled MediaRemote resource is missing: \(name)."
            case .invalidResource(let name):
                return "The bundled MediaRemote resource has an invalid path or file type: \(name)."
            case .unreadableResource(let name, let reason):
                return "The bundled MediaRemote resource could not be read: \(name) (\(reason))."
            case .hashMismatch(let name):
                return "SHA-256 validation failed for the bundled MediaRemote resource: \(name)."
            }
        }
    }

    private static let expectedScriptSHA256 =
        "902c7ddeda599cc595ff99d7607a4e095b301b6706a8838ecb8a4053aaa193f0"
    private static let expectedFrameworkSHA256 =
        "829e9cdbce5602a92f56f125e3921a82215fa6cc09a8e6fdff39d3b991dbcdac"

    static func isUserConsentEnabled() -> Bool {
        guard !runtimeBlockState.read() else { return false }
        do {
            let allowed = try MediaRemoteConsentSecureStore.isAllowed()
            Defaults[.allowBundledMediaRemoteAdapter] = allowed
            return allowed
        } catch {
            Defaults[.allowBundledMediaRemoteAdapter] = false
            return false
        }
    }

    static func setUserConsent(_ enabled: Bool) throws {
        if !enabled {
            // Fail closed immediately even if durable deletion fails.
            runtimeBlockState.set(true)
        }
        do {
            try MediaRemoteConsentSecureStore.setAllowed(enabled)
        } catch {
            Defaults[.allowBundledMediaRemoteAdapter] = false
            throw error
        }
        runtimeBlockState.set(!enabled)
        Defaults[.allowBundledMediaRemoteAdapter] = enabled
    }

    static func disableUserConsentAfterValidationFailure() {
        runtimeBlockState.set(true)
        try? MediaRemoteConsentSecureStore.setAllowed(false)
        Defaults[.allowBundledMediaRemoteAdapter] = false
    }

    /// Validates user consent, resource boundaries, and checked-in hashes.
    @discardableResult
    static func validateInstallation() throws -> Installation {
        let prepared = try prepareExecution()
        try? prepared.frameworkExecutableHandle.close()
        return prepared.installation
    }

    /// Opens and verifies the exact script/framework bytes that will be handed
    /// to Perl. The framework descriptor remains open across process launch so
    /// a same-user process cannot swap the path after validation.
    static func prepareExecution() throws -> PreparedExecution {
        guard isUserConsentEnabled() else {
            throw ValidationError.consentRequired
        }

        let installation = try resolveInstallation()

        let (scriptData, scriptHandle) = try openRegularFile(
            installation.scriptURL,
            name: "mediaremote-adapter.pl"
        )
        defer { try? scriptHandle.close() }
        let (frameworkData, frameworkHandle) = try openRegularFile(
            installation.frameworkExecutableURL,
            name: "MediaRemoteAdapter"
        )

        try validateSHA256(
            data: scriptData,
            expected: expectedScriptSHA256,
            name: "mediaremote-adapter.pl"
        )
        try validateSHA256(
            data: frameworkData,
            expected: expectedFrameworkSHA256,
            name: "MediaRemoteAdapter"
        )

        guard let scriptSource = String(data: scriptData, encoding: .utf8),
              !scriptSource.utf8.contains(0) else {
            try? frameworkHandle.close()
            throw ValidationError.invalidResource("mediaremote-adapter.pl")
        }
        try frameworkHandle.seek(toOffset: 0)

        return PreparedExecution(
            installation: installation,
            scriptSource: scriptSource,
            frameworkExecutableHandle: frameworkHandle
        )
    }

    private static func resolveInstallation() throws -> Installation {
        let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath()

        guard let scriptURL = Bundle.main.url(
            forResource: "mediaremote-adapter",
            withExtension: "pl"
        ) else {
            throw ValidationError.missingResource("mediaremote-adapter.pl")
        }

        guard let resourceURL = Bundle.main.resourceURL else {
            throw ValidationError.missingResource("app resources directory")
        }

        let frameworkURL = resourceURL.appendingPathComponent(
            "MediaRemoteAdapter.framework",
            isDirectory: true
        )
        guard let frameworkBundle = Bundle(url: frameworkURL),
              let frameworkExecutableURL = frameworkBundle.executableURL
        else {
            throw ValidationError.missingResource("MediaRemoteAdapter.framework")
        }

        try requireRegularFile(scriptURL, name: "mediaremote-adapter.pl")
        try requireDirectory(frameworkURL, name: "MediaRemoteAdapter.framework")
        try requireRegularFile(frameworkExecutableURL, name: "MediaRemoteAdapter")

        try requireContained(scriptURL, in: appURL, name: "mediaremote-adapter.pl")
        try requireContained(frameworkURL, in: appURL, name: "MediaRemoteAdapter.framework")
        try requireContained(
            frameworkExecutableURL,
            in: frameworkURL.resolvingSymlinksInPath(),
            name: "MediaRemoteAdapter"
        )

        return Installation(
            scriptURL: scriptURL,
            frameworkURL: frameworkURL,
            frameworkExecutableURL: frameworkExecutableURL
        )
    }

    private static func requireRegularFile(_ url: URL, name: String) throws {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw ValidationError.invalidResource(name)
            }
        } catch let error as ValidationError {
            throw error
        } catch {
            throw ValidationError.unreadableResource(name, error.localizedDescription)
        }
    }

    private static func requireDirectory(_ url: URL, name: String) throws {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw ValidationError.invalidResource(name)
            }
        } catch let error as ValidationError {
            throw error
        } catch {
            throw ValidationError.unreadableResource(name, error.localizedDescription)
        }
    }

    private static func requireContained(_ url: URL, in rootURL: URL, name: String) throws {
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath.hasPrefix(rootPath + "/") else {
            throw ValidationError.invalidResource(name)
        }
    }

    private static func openRegularFile(_ url: URL, name: String) throws -> (Data, FileHandle) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ValidationError.unreadableResource(name, String(cString: strerror(errno)))
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw ValidationError.unreadableResource(name, reason)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw ValidationError.invalidResource(name)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let data = try handle.readToEnd() ?? Data()
            try handle.seek(toOffset: 0)
            return (data, handle)
        } catch {
            try? handle.close()
            throw ValidationError.unreadableResource(name, error.localizedDescription)
        }
    }

    private static func validateSHA256(data: Data, expected: String, name: String) throws {
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual == expected else {
            throw ValidationError.hashMismatch(name)
        }
    }
}
