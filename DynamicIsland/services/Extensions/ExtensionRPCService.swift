/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import AppKit
import Defaults
import AtollExtensionKit
import UniformTypeIdentifiers

/// Handles JSON-RPC method calls for a single WebSocket connection.
/// Mirrors the functionality of `ExtensionXPCService` but uses JSON-RPC transport.
@MainActor
final class ExtensionRPCService {
    let bundleIdentifier: String
    private let connectionID: UUID?
    private weak var server: ExtensionRPCServer?

    private let liveActivityManager = ExtensionLiveActivityManager.shared
    private let widgetManager = ExtensionLockScreenWidgetManager.shared
    private let notchManager = ExtensionNotchExperienceManager.shared
    private let authorizationManager = ExtensionAuthorizationManager.shared

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private static let maximumShelfItemDataSize = 64 * 1024 * 1024

    private enum ShelfFileReadResult {
        case data(Data)
        case tooLarge
        case unavailable
    }

    // Keys whose values represent Swift enums that use {"type":...} in client format.
    // These need to be transformed to Swift Codable format: {"caseName": {params}}.
    private static let enumKeys: Set<String> = [
        "leadingIcon", "trailingContent", "progressIndicator",
        "badgeIcon", "leadingContent", "icon", "tint"
    ]

    // Enum-typed fields that can appear inside arrays (like content elements)
    private static let contentElementTypeFields: Set<String> = [
        "text", "icon", "progress", "graph", "gauge", "spacer", "divider", "webView"
    ]

    init(bundleIdentifier: String, server: ExtensionRPCServer, connectionID: UUID? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.server = server
        self.connectionID = connectionID
    }

    // MARK: - Method Routing

    func handleRequest(_ request: RPCRequest) async -> Data {
        let result: Codable

        switch request.method {
        case "atoll.getVersion":
            result = handleGetVersion(id: request.id)

        case "atoll.requestAuthorization":
            result = handleRequestAuthorization(params: request.params, id: request.id)

        case "atoll.checkAuthorization":
            result = handleCheckAuthorization(params: request.params, id: request.id)

        case "atoll.presentLiveActivity":
            result = handlePresentLiveActivity(params: request.params, id: request.id)

        case "atoll.updateLiveActivity":
            result = handleUpdateLiveActivity(params: request.params, id: request.id)

        case "atoll.dismissLiveActivity":
            result = handleDismissLiveActivity(params: request.params, id: request.id)

        case "atoll.presentLockScreenWidget":
            result = handlePresentLockScreenWidget(params: request.params, id: request.id)

        case "atoll.updateLockScreenWidget":
            result = handleUpdateLockScreenWidget(params: request.params, id: request.id)

        case "atoll.dismissLockScreenWidget":
            result = handleDismissLockScreenWidget(params: request.params, id: request.id)

        case "atoll.presentNotchExperience":
            result = handlePresentNotchExperience(params: request.params, id: request.id)

        case "atoll.updateNotchExperience":
            result = handleUpdateNotchExperience(params: request.params, id: request.id)

        case "atoll.dismissNotchExperience":
            result = handleDismissNotchExperience(params: request.params, id: request.id)

        // MARK: File Sharing
        case "atoll.getShelfItems":
            result = await handleGetShelfItems(params: request.params, id: request.id)

        case "atoll.getShelfItemData":
            result = await handleGetShelfItemData(params: request.params, id: request.id)

        case "atoll.showFilePicker":
            result = handleShowFilePicker(params: request.params, id: request.id)

        case "atoll.shareShelfItems":
            result = await handleShareShelfItems(params: request.params, id: request.id)

        case "atoll.addFilesToShelf":
            result = handleAddFilesToShelf(params: request.params, id: request.id)

        case "atoll.subscribeShelfEvents":
            result = handleSubscribeShelfEvents(params: request.params, id: request.id)

        default:
            result = RPCErrorResponse(
                error: RPCErrorObject(code: RPCErrorCode.methodNotFound, message: "Method not found: \(request.method)"),
                id: request.id
            )
        }

        return (try? encoder.encode(result)) ?? Data()
    }

    // MARK: - Version

    private func handleGetVersion(id: String) -> RPCSuccessResponse {
        RPCSuccessResponse(
            result: ["version": .string(AtollExtensionKitVersion)],
            id: id
        )
    }

    // MARK: - Authorization

    private func handleRequestAuthorization(params: RPCParams?, id: String) -> Codable {
        guard authorizationManager.isExtensionsFeatureEnabled else {
            return RPCErrorResponse(
                error: RPCErrorObject(code: RPCErrorCode.featureDisabled, message: "Extensions are disabled"),
                id: id
            )
        }

        let entry = authorizationManager.ensureEntryExists(
            bundleIdentifier: bundleIdentifier,
            appName: bundleIdentifier
        )
        logDiagnostics("RPC client \(bundleIdentifier) requested authorization (status: \(entry.status.rawValue))")

        return RPCSuccessResponse(
            result: ["authorized": .bool(authorizationManager.isBundleAuthorized(bundleIdentifier))],
            id: id
        )
    }

    private func handleCheckAuthorization(params: RPCParams?, id: String) -> Codable {
        guard authorizationManager.isExtensionsFeatureEnabled else {
            return RPCSuccessResponse(result: ["authorized": .bool(false)], id: id)
        }

        let authorized = authorizationManager.isBundleAuthorized(bundleIdentifier)

        return RPCSuccessResponse(result: ["authorized": .bool(authorized)], id: id)
    }

    // MARK: - Live Activities

    private func handlePresentLiveActivity(params: RPCParams?, id: String) -> Codable {
        guard let descriptorData = params?.jsonData(for: "descriptor") else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing descriptor", id: id)
        }

        do {
            let transformed = Self.transformClientJSON(descriptorData)
            let descriptor = try decoder.decode(AtollLiveActivityDescriptor.self, from: transformed)
            guard descriptor.bundleIdentifier == bundleIdentifier else {
                return errorResponse(code: RPCErrorCode.invalidParams, message: "Bundle identifier mismatch", id: id)
            }
            try ExtensionDescriptorValidator.validate(descriptor)
            try liveActivityManager.present(descriptor: descriptor, bundleIdentifier: bundleIdentifier)
            logDiagnostics("RPC: Presented live activity \(descriptor.id) for \(bundleIdentifier)")
            return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
        } catch let error as ExtensionValidationError {
            return errorResponse(from: error, id: id)
        } catch {
            logDiagnostics("RPC: Decode error for presentLiveActivity: \(error)")
            logDiagnostics("RPC: Raw payload: \(String(data: descriptorData, encoding: .utf8) ?? "<binary>")")
            return errorResponse(code: RPCErrorCode.internalError, message: error.localizedDescription, id: id)
        }
    }

    private func handleUpdateLiveActivity(params: RPCParams?, id: String) -> Codable {
        guard let descriptorData = params?.jsonData(for: "descriptor") else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing descriptor", id: id)
        }

        do {
            let transformed = Self.transformClientJSON(descriptorData)
            let descriptor = try decoder.decode(AtollLiveActivityDescriptor.self, from: transformed)
            guard descriptor.bundleIdentifier == bundleIdentifier else {
                return errorResponse(code: RPCErrorCode.invalidParams, message: "Bundle identifier mismatch", id: id)
            }
            try liveActivityManager.update(descriptor: descriptor, bundleIdentifier: bundleIdentifier)
            logDiagnostics("RPC: Updated live activity \(descriptor.id) for \(bundleIdentifier)")
            return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
        } catch let error as ExtensionValidationError {
            return errorResponse(from: error, id: id)
        } catch {
            logDiagnostics("RPC: Decode error for updateLiveActivity: \(error)")
            return errorResponse(code: RPCErrorCode.internalError, message: error.localizedDescription, id: id)
        }
    }

    private func handleDismissLiveActivity(params: RPCParams?, id: String) -> Codable {
        guard authorizationManager.canProcessLiveActivityRequest(from: bundleIdentifier) else {
            return errorResponse(code: RPCErrorCode.unauthorized, message: "Live activity access is not authorized", id: id)
        }
        guard let activityID = params?["activityID"]?.stringValue else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing activityID", id: id)
        }
        liveActivityManager.dismiss(activityID: activityID, bundleIdentifier: bundleIdentifier)
        logDiagnostics("RPC: Dismissed live activity \(activityID) for \(bundleIdentifier)")
        return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
    }

    // MARK: - Lock Screen Widgets

    private func handlePresentLockScreenWidget(params: RPCParams?, id: String) -> Codable {
        guard let descriptorData = params?.jsonData(for: "descriptor") else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing descriptor", id: id)
        }

        do {
            let transformed = Self.transformClientJSON(descriptorData)
            let descriptor = try decoder.decode(AtollLockScreenWidgetDescriptor.self, from: transformed)
            guard descriptor.bundleIdentifier == bundleIdentifier else {
                return errorResponse(code: RPCErrorCode.invalidParams, message: "Bundle identifier mismatch", id: id)
            }
            try ExtensionDescriptorValidator.validate(descriptor)
            try widgetManager.present(descriptor: descriptor, bundleIdentifier: bundleIdentifier)
            logDiagnostics("RPC: Presented widget \(descriptor.id) for \(bundleIdentifier)")
            return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
        } catch let error as ExtensionValidationError {
            return errorResponse(from: error, id: id)
        } catch {
            logDiagnostics("RPC: Decode error for presentWidget: \(error)")
            logDiagnostics("RPC: Raw payload: \(String(data: descriptorData, encoding: .utf8) ?? "<binary>")")
            return errorResponse(code: RPCErrorCode.internalError, message: error.localizedDescription, id: id)
        }
    }

    private func handleUpdateLockScreenWidget(params: RPCParams?, id: String) -> Codable {
        guard let descriptorData = params?.jsonData(for: "descriptor") else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing descriptor", id: id)
        }

        do {
            let transformed = Self.transformClientJSON(descriptorData)
            let descriptor = try decoder.decode(AtollLockScreenWidgetDescriptor.self, from: transformed)
            guard descriptor.bundleIdentifier == bundleIdentifier else {
                return errorResponse(code: RPCErrorCode.invalidParams, message: "Bundle identifier mismatch", id: id)
            }
            try widgetManager.update(descriptor: descriptor, bundleIdentifier: bundleIdentifier)
            logDiagnostics("RPC: Updated widget \(descriptor.id) for \(bundleIdentifier)")
            return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
        } catch let error as ExtensionValidationError {
            return errorResponse(from: error, id: id)
        } catch {
            logDiagnostics("RPC: Decode error for updateWidget: \(error)")
            return errorResponse(code: RPCErrorCode.internalError, message: error.localizedDescription, id: id)
        }
    }

    private func handleDismissLockScreenWidget(params: RPCParams?, id: String) -> Codable {
        guard authorizationManager.canProcessLockScreenRequest(from: bundleIdentifier) else {
            return errorResponse(code: RPCErrorCode.unauthorized, message: "Lock screen widget access is not authorized", id: id)
        }
        guard let widgetID = params?["widgetID"]?.stringValue else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing widgetID", id: id)
        }
        widgetManager.dismiss(widgetID: widgetID, bundleIdentifier: bundleIdentifier)
        logDiagnostics("RPC: Dismissed widget \(widgetID) for \(bundleIdentifier)")
        return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
    }

    // MARK: - Notch Experiences

    private func handlePresentNotchExperience(params: RPCParams?, id: String) -> Codable {
        guard let descriptorData = params?.jsonData(for: "descriptor") else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing descriptor", id: id)
        }

        do {
            let transformed = Self.transformClientJSON(descriptorData)
            let descriptor = try decoder.decode(AtollNotchExperienceDescriptor.self, from: transformed)
            guard descriptor.bundleIdentifier == bundleIdentifier else {
                return errorResponse(code: RPCErrorCode.invalidParams, message: "Bundle identifier mismatch", id: id)
            }
            try ExtensionDescriptorValidator.validate(descriptor)
            try notchManager.present(descriptor: descriptor, bundleIdentifier: bundleIdentifier)
            logDiagnostics("RPC: Presented notch experience \(descriptor.id) for \(bundleIdentifier)")
            return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
        } catch let error as ExtensionValidationError {
            return errorResponse(from: error, id: id)
        } catch {
            logDiagnostics("RPC: Decode error for presentNotchExperience: \(error)")
            logDiagnostics("RPC: Raw payload: \(String(data: descriptorData, encoding: .utf8) ?? "<binary>")")
            return errorResponse(code: RPCErrorCode.internalError, message: error.localizedDescription, id: id)
        }
    }

    private func handleUpdateNotchExperience(params: RPCParams?, id: String) -> Codable {
        guard let descriptorData = params?.jsonData(for: "descriptor") else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing descriptor", id: id)
        }

        do {
            let transformed = Self.transformClientJSON(descriptorData)
            let descriptor = try decoder.decode(AtollNotchExperienceDescriptor.self, from: transformed)
            guard descriptor.bundleIdentifier == bundleIdentifier else {
                return errorResponse(code: RPCErrorCode.invalidParams, message: "Bundle identifier mismatch", id: id)
            }
            try notchManager.update(descriptor: descriptor, bundleIdentifier: bundleIdentifier)
            logDiagnostics("RPC: Updated notch experience \(descriptor.id) for \(bundleIdentifier)")
            return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
        } catch let error as ExtensionValidationError {
            return errorResponse(from: error, id: id)
        } catch {
            logDiagnostics("RPC: Decode error for updateNotchExperience: \(error)")
            return errorResponse(code: RPCErrorCode.internalError, message: error.localizedDescription, id: id)
        }
    }

    private func handleDismissNotchExperience(params: RPCParams?, id: String) -> Codable {
        guard authorizationManager.canProcessNotchExperienceRequest(from: bundleIdentifier) else {
            return errorResponse(code: RPCErrorCode.unauthorized, message: "Notch experience access is not authorized", id: id)
        }
        guard let experienceID = params?["experienceID"]?.stringValue else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing experienceID", id: id)
        }
        notchManager.dismiss(experienceID: experienceID, bundleIdentifier: bundleIdentifier)
        logDiagnostics("RPC: Dismissed notch experience \(experienceID) for \(bundleIdentifier)")
        return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
    }

    // MARK: - Helpers

    private func errorResponse(code: Int, message: String, id: String) -> RPCErrorResponse {
        RPCErrorResponse(
            error: RPCErrorObject(code: code, message: message),
            id: id
        )
    }

    private func errorResponse(from error: ExtensionValidationError, id: String) -> RPCErrorResponse {
        let code: Int
        switch error {
        case .featureDisabled:     code = RPCErrorCode.featureDisabled
        case .unauthorized:        code = RPCErrorCode.unauthorized
        case .invalidDescriptor:   code = RPCErrorCode.descriptorInvalid
        case .exceedsCapacity:     code = RPCErrorCode.capacityExceeded
        case .unsupportedContent:  code = RPCErrorCode.unsupported
        case .rateLimited:         code = RPCErrorCode.internalError
        case .duplicateIdentifier: code = RPCErrorCode.descriptorInvalid
        }
        return RPCErrorResponse(
            error: RPCErrorObject(code: code, message: error.localizedDescription),
            id: id
        )
    }

    private func logDiagnostics(_ message: String) {
        guard Defaults[.extensionDiagnosticsLoggingEnabled] else { return }
        Logger.log(message, category: .extensions)
    }

    // MARK: - File Sharing Authorization Check

    private func checkFileSharingAuthorization(id: String) -> RPCErrorResponse? {
        guard authorizationManager.isExtensionsFeatureEnabled else {
            return errorResponse(code: RPCErrorCode.featureDisabled, message: "Extensions are disabled", id: id)
        }
        guard authorizationManager.isFileSharingEnabled else {
            return errorResponse(code: RPCErrorCode.featureDisabled, message: "Extension file sharing is disabled", id: id)
        }
        guard authorizationManager.canProcessFileSharingRequest(from: bundleIdentifier) else {
            return errorResponse(code: RPCErrorCode.unauthorized, message: "File sharing access not granted", id: id)
        }
        return nil
    }

    private static func isValidShelfFileName(_ fileName: String) -> Bool {
        guard !fileName.isEmpty,
              fileName.utf8.count <= 255,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\\"),
              !fileName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        return URL(fileURLWithPath: fileName).lastPathComponent == fileName
    }

    private func shelfItemDataResponse(
        data: Data,
        fileName: String,
        mimeType: String,
        id: String
    ) -> Codable {
        guard data.count <= Self.maximumShelfItemDataSize else {
            return errorResponse(
                code: RPCErrorCode.unsupported,
                message: "Shelf item exceeds the 64 MiB transfer limit",
                id: id
            )
        }
        return RPCSuccessResponse(result: [
            "data": .string(data.base64EncodedString()),
            "fileName": .string(fileName),
            "mimeType": .string(mimeType)
        ], id: id)
    }

    // MARK: - File Sharing Handlers

    private func handleGetShelfItems(params: RPCParams?, id: String) async -> Codable {
        if let err = checkFileSharingAuthorization(id: id) { return err }

        let items = ShelfStateViewModel.shared.items
        var result: [RPCValue] = []

        for item in items {
            var entry: [String: RPCValue] = [
                "id": .string(item.id.uuidString),
                "name": .string(item.displayName)
            ]
            switch item.kind {
            case .file(let bookmark):
                entry["kind"] = .string("file")
                let bookmarkObj = Bookmark(data: bookmark)
                let result = await bookmarkObj.resolveAsync()
                if let url = result.url {
                    entry["path"] = .string(url.path)
                    // File attribute lookup off MainActor
                    let attrs = await Task.detached(priority: .userInitiated) { [url] in
                        try? FileManager.default.attributesOfItem(atPath: url.path)
                    }.value
                    if let attrs = attrs, let size = attrs[.size] as? Int {
                        entry["size"] = .int(size)
                    }
                }
            case .text(let string):
                entry["kind"] = .string("text")
                entry["textContent"] = .string(string)
            case .link(let url):
                entry["kind"] = .string("link")
                entry["url"] = .string(url.absoluteString)
            }
            result.append(.object(entry))
        }

        logDiagnostics("RPC: getShelfItems returned \(result.count) items for \(bundleIdentifier)")
        return RPCSuccessResponse(result: ["items": .array(result)], id: id)
    }

    private func handleGetShelfItemData(params: RPCParams?, id: String) async -> Codable {
        if let err = checkFileSharingAuthorization(id: id) { return err }

        guard let itemID = params?["itemID"]?.stringValue,
              let uuid = UUID(uuidString: itemID) else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing or invalid itemID", id: id)
        }

        guard let item = ShelfStateViewModel.shared.items.first(where: { $0.id == uuid }) else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Item not found", id: id)
        }

        switch item.kind {
        case .file(let bookmark):
            let bookmarkObj = Bookmark(data: bookmark)
            let result = await bookmarkObj.resolveAsync()
            guard let url = result.url else {
                return errorResponse(code: RPCErrorCode.internalError, message: "Cannot resolve file bookmark", id: id)
            }
            let maximumDataSize = Self.maximumShelfItemDataSize
            let fileReadResult = await Task.detached(priority: .userInitiated) { [url] in
                url.accessSecurityScopedResource { scopedURL -> ShelfFileReadResult in
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: scopedURL.path),
                          attributes[.type] as? FileAttributeType == .typeRegular,
                          let fileSize = attributes[.size] as? NSNumber else {
                        return .unavailable
                    }
                    guard fileSize.uint64Value <= UInt64(maximumDataSize) else {
                        return .tooLarge
                    }

                    do {
                        let fileHandle = try FileHandle(forReadingFrom: scopedURL)
                        defer { try? fileHandle.close() }
                        let data = try fileHandle.read(upToCount: maximumDataSize + 1) ?? Data()
                        guard data.count <= maximumDataSize else { return .tooLarge }
                        return .data(data)
                    } catch {
                        return .unavailable
                    }
                }
            }.value

            let data: Data
            switch fileReadResult {
            case .data(let fileData):
                data = fileData
            case .tooLarge:
                return errorResponse(
                    code: RPCErrorCode.unsupported,
                    message: "Shelf item exceeds the 64 MiB transfer limit",
                    id: id
                )
            case .unavailable:
                return errorResponse(code: RPCErrorCode.internalError, message: "Cannot read file data", id: id)
            }

            logDiagnostics("RPC: getShelfItemData returned \(data.count) bytes for \(bundleIdentifier)")
            return shelfItemDataResponse(
                data: data,
                fileName: url.lastPathComponent,
                mimeType: url.mimeType ?? "application/octet-stream",
                id: id
            )
        case .text(let string):
            return shelfItemDataResponse(
                data: Data(string.utf8),
                fileName: "text.txt",
                mimeType: "text/plain",
                id: id
            )
        case .link(let url):
            return shelfItemDataResponse(
                data: Data(url.absoluteString.utf8),
                fileName: "link.url",
                mimeType: "text/uri-list",
                id: id
            )
        }
    }

    private func handleShowFilePicker(params: RPCParams?, id: String) -> Codable {
        if let err = checkFileSharingAuthorization(id: id) { return err }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Select files to share"

        let response = panel.runModal()
        guard response == .OK, !panel.urls.isEmpty else {
            return RPCSuccessResponse(result: ["itemIDs": .array([])], id: id)
        }

        var newItemIDs: [RPCValue] = []
        var newItems: [ShelfItem] = []

        for url in panel.urls {
            if let bookmark = try? Bookmark(url: url) {
                let item = ShelfItem(kind: .file(bookmark: bookmark.data))
                newItems.append(item)
                newItemIDs.append(.string(item.id.uuidString))
            }
        }

        ShelfStateViewModel.shared.add(newItems)
        logDiagnostics("RPC: showFilePicker added \(newItems.count) items for \(bundleIdentifier)")
        return RPCSuccessResponse(result: ["itemIDs": .array(newItemIDs)], id: id)
    }

    private func handleShareShelfItems(params: RPCParams?, id: String) async -> Codable {
        if let err = checkFileSharingAuthorization(id: id) { return err }

        guard let itemIDsValue = params?["itemIDs"],
              case .array(let itemIDArray) = itemIDsValue else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing itemIDs array", id: id)
        }

        let provider = params?["provider"]?.stringValue ?? "AirDrop"
        let itemIDs = itemIDArray.compactMap { $0.stringValue }.compactMap { UUID(uuidString: $0) }
        let items = ShelfStateViewModel.shared.items.filter { itemIDs.contains($0.id) }

        guard !items.isEmpty else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "No matching shelf items found", id: id)
        }

        // Use async resolution since this is called from an async context
        let urls = await ShelfStateViewModel.shared.resolveFileURLsAsync(for: items)
        guard !urls.isEmpty else {
            return errorResponse(code: RPCErrorCode.internalError, message: "Could not resolve file URLs", id: id)
        }

        // Find and invoke the sharing service
        QuickShareService.shared.ensureDiscovered()
        if let shareProvider = QuickShareService.shared.availableProviders.first(where: { $0.id == provider }) {
            Task {
                await QuickShareService.shared.shareFilesOrText(urls, using: shareProvider, from: nil)
            }
            logDiagnostics("RPC: shareShelfItems sharing \(urls.count) files via \(provider) for \(bundleIdentifier)")
            return RPCSuccessResponse(result: ["success": .bool(true), "fileCount": .int(urls.count)], id: id)
        } else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Provider '\(provider)' not found", id: id)
        }
    }

    private func handleAddFilesToShelf(params: RPCParams?, id: String) -> Codable {
        if let err = checkFileSharingAuthorization(id: id) { return err }

        var newItems: [ShelfItem] = []
        var newItemIDs: [RPCValue] = []

        // Handle base64-encoded file data
        if let filesValue = params?["files"],
           case .array(let filesArray) = filesValue {
            for fileValue in filesArray {
                guard case .object(let fileObj) = fileValue,
                      let dataStr = fileObj["data"]?.stringValue,
                      let fileName = fileObj["fileName"]?.stringValue,
                      Self.isValidShelfFileName(fileName),
                      let fileData = Data(base64Encoded: dataStr) else { continue }

                let fileManager = FileManager.default
                let storageRoot = fileManager.temporaryDirectory
                    .appendingPathComponent("AtollExtensionFiles", isDirectory: true)
                let itemDirectory = storageRoot
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                var itemDirectoryCreated = false

                do {
                    try fileManager.createDirectory(
                        at: storageRoot,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    try fileManager.createDirectory(
                        at: itemDirectory,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                    itemDirectoryCreated = true

                    let fileURL = itemDirectory.appendingPathComponent(fileName, isDirectory: false)
                    try fileData.write(to: fileURL, options: .atomic)
                    let bookmark = try Bookmark(url: fileURL)
                    let item = ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)
                    newItems.append(item)
                    newItemIDs.append(.string(item.id.uuidString))
                } catch {
                    if itemDirectoryCreated {
                        try? fileManager.removeItem(at: itemDirectory)
                    }
                }
            }
        }

        // Handle text content
        if let text = params?["text"]?.stringValue, !text.isEmpty {
            let item = ShelfItem(kind: .text(string: text))
            newItems.append(item)
            newItemIDs.append(.string(item.id.uuidString))
        }

        ShelfStateViewModel.shared.add(newItems)
        logDiagnostics("RPC: addFilesToShelf added \(newItems.count) items for \(bundleIdentifier)")
        return RPCSuccessResponse(result: ["itemIDs": .array(newItemIDs)], id: id)
    }

    private func handleSubscribeShelfEvents(params: RPCParams?, id: String) -> Codable {
        if let err = checkFileSharingAuthorization(id: id) { return err }

        guard let connectionID,
              server?.registerShelfSubscription(connectionID: connectionID) == true else {
            return errorResponse(code: RPCErrorCode.unauthorized, message: "Shelf event subscription is not authorized", id: id)
        }
        logDiagnostics("RPC: subscribeShelfEvents registered for \(bundleIdentifier)")
        return RPCSuccessResponse(result: ["subscribed": .bool(true)], id: id)
    }

    // MARK: - Client JSON Transformation

    /// Converts client wire format to Swift Codable format for enum types.
    ///
    /// Client sends: `{ "type": "symbol", "name": "timer", "size": 16 }`
    /// Swift expects: `{ "symbol": { "name": "timer", "size": 16 } }`
    ///
    /// For enums with unnamed parameters (e.g., `case text(String, font:, color:)`):
    /// Client sends: `{ "type": "text", "text": "LIVE", "font": {...} }`
    /// Swift expects: `{ "text": { "_0": "LIVE", "font": {...} } }`
    static func transformClientJSON(_ data: Data) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        let transformed = transformObject(json)
        return (try? JSONSerialization.data(withJSONObject: transformed)) ?? data
    }

    private static func transformObject(_ obj: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]

        for (key, value) in obj {
            if let dict = value as? [String: Any] {
                if enumKeys.contains(key), let typeName = dict["type"] as? String {
                    // Transform: { "type": "symbol", ... } → { "symbol": { ... } }
                    result[key] = transformEnumValue(dict, typeName: typeName)
                } else {
                    result[key] = transformObject(dict)
                }
            } else if let arr = value as? [[String: Any]] {
                // Arrays like "content", "elements", "sections"
                result[key] = arr.map { item in
                    if let typeName = item["type"] as? String,
                       (key == "content" || key == "elements") {
                        return transformEnumValue(item, typeName: typeName)
                    }
                    return transformObject(item)
                }
            } else {
                result[key] = value
            }
        }

        return result
    }

    /// Transforms `{ "type": "caseName", ...params }` → `{ "caseName": { ...params } }`.
    /// Handles special cases where Swift enum cases have unnamed first parameters:
    /// - `text` / `marquee`: `text` field → `_0`
    /// - `icon`: `icon` field → `_0` (AtollIconDescriptor)
    /// - `progress`: `indicator` field → `_0` (AtollProgressIndicator)
    /// - `webView`: `content` field → `_0` (AtollWidgetWebContentDescriptor)
    /// - `animation`: `data` field → `_0` (Data)
    private static func transformEnumValue(_ dict: [String: Any], typeName: String) -> [String: Any] {
        var inner: [String: Any] = [:]

        for (k, v) in dict where k != "type" {
            if let nestedDict = v as? [String: Any] {
                // Check if this nested dict is an enum-typed field
                if (enumKeys.contains(k) || k == "indicator"),
                   let nestedType = nestedDict["type"] as? String {
                    inner[k] = transformEnumValue(nestedDict, typeName: nestedType)
                } else {
                    inner[k] = transformObject(nestedDict)
                }
            } else if let nestedArr = v as? [[String: Any]] {
                inner[k] = nestedArr.map { item in
                    if let t = item["type"] as? String {
                        return transformEnumValue(item, typeName: t)
                    }
                    return transformObject(item)
                }
            } else {
                inner[k] = v
            }
        }

        // Handle unnamed first parameter for specific enum cases.
        // Swift's auto-synthesized Codable encodes unnamed associated values as `_0`, `_1`, etc.
        switch typeName {
        case "text":
            // AtollTrailingContent.text(String, ...) AND AtollWidgetContentElement.text(String, ...)
            if let textValue = inner.removeValue(forKey: "text") {
                inner["_0"] = textValue
            }
        case "marquee":
            // AtollTrailingContent.marquee(String, ...)
            if let textValue = inner.removeValue(forKey: "text") {
                inner["_0"] = textValue
            }
        case "icon":
            // AtollWidgetContentElement.icon(AtollIconDescriptor, tint:)
            if let iconValue = inner.removeValue(forKey: "icon") {
                inner["_0"] = iconValue
            }
        case "progress":
            // AtollWidgetContentElement.progress(AtollProgressIndicator, value:, color:)
            if let indicatorValue = inner.removeValue(forKey: "indicator") {
                inner["_0"] = indicatorValue
            }
        case "webView":
            // AtollWidgetContentElement.webView(AtollWidgetWebContentDescriptor)
            if let contentValue = inner.removeValue(forKey: "content") {
                inner["_0"] = contentValue
            }
        case "animation":
            // AtollTrailingContent.animation(data:, size:) — data is named but let's be safe
            break
        default:
            break
        }

        return [typeName: inner]
    }
}

// MARK: - URL MIME Type Helper

private extension URL {
    var mimeType: String? {
        guard let uti = UTType(filenameExtension: self.pathExtension) else { return nil }
        return uti.preferredMIMEType
    }
}
