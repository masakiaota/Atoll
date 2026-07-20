//
//  ExtensionWebContentSecurityPolicy.swift
//  DynamicIsland
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum ExtensionWebContentNetworkPolicy: Equatable {
    case blocked
    case localhostOnly
    case remoteOnly
    case remoteAndLocalhost

    init(allowRemoteRequests: Bool, allowLocalhostRequests: Bool) {
        switch (allowRemoteRequests, allowLocalhostRequests) {
        case (false, false):
            self = .blocked
        case (false, true):
            self = .localhostOnly
        case (true, false):
            self = .remoteOnly
        case (true, true):
            self = .remoteAndLocalhost
        }
    }

    var requiresNetworkRuleList: Bool {
        self != .remoteAndLocalhost
    }
}

struct ExtensionProtectedWebDocument {
    let html: String
    let networkPolicy: ExtensionWebContentNetworkPolicy
}

enum ExtensionWebContentSecurityPolicy {
    static func makeDocument(
        sourceHTML: String,
        networkPolicy: ExtensionWebContentNetworkPolicy,
        nonce requestedNonce: String = makeNonce()
    ) -> ExtensionProtectedWebDocument {
        let nonce = isValidNonce(requestedNonce) ? requestedNonce : makeNonce()
        let policy = contentSecurityPolicy(networkPolicy: networkPolicy, nonce: nonce)
        let protectedBody = addingNonceToInlineScriptsAndStyles(in: sourceHTML, nonce: nonce)
        let prefix = "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"></head><body>"
        return ExtensionProtectedWebDocument(
            html: prefix + protectedBody + "</body></html>",
            networkPolicy: networkPolicy
        )
    }

    static func contentSecurityPolicy(
        networkPolicy: ExtensionWebContentNetworkPolicy,
        nonce: String
    ) -> String {
        let networkSources = sources(for: networkPolicy)
        let networkOrNone = networkSources.isEmpty ? "'none'" : networkSources.joined(separator: " ")
        let scriptSources = (["'nonce-\(nonce)'"] + networkSources).joined(separator: " ")
        let styleSources = (["'nonce-\(nonce)'"] + networkSources).joined(separator: " ")
        let imageSources = (["data:", "blob:"] + networkSources).joined(separator: " ")
        let fontSources = (["data:"] + networkSources).joined(separator: " ")
        let mediaSources = (["data:", "blob:"] + networkSources).joined(separator: " ")

        return [
            "default-src 'none'",
            "base-uri 'none'",
            "object-src 'none'",
            "script-src \(scriptSources)",
            "script-src-attr 'none'",
            "style-src \(styleSources)",
            "style-src-attr 'unsafe-inline'",
            "img-src \(imageSources)",
            "font-src \(fontSources)",
            "media-src \(mediaSources)",
            "connect-src \(networkOrNone)",
            "frame-src \(networkOrNone)",
            "child-src \(networkOrNone)",
            "form-action \(networkOrNone)",
            "worker-src 'none'",
            "manifest-src 'none'"
        ].joined(separator: "; ")
    }

    static func networkRuleListIdentifier(for policy: ExtensionWebContentNetworkPolicy) -> String? {
        switch policy {
        case .blocked:
            return "com.ebullioscopic.Atoll.extension-web.block-network-v1"
        case .localhostOnly:
            return "com.ebullioscopic.Atoll.extension-web.allow-loopback-v1"
        case .remoteOnly:
            return "com.ebullioscopic.Atoll.extension-web.block-loopback-v1"
        case .remoteAndLocalhost:
            return nil
        }
    }

    static func networkRuleListJSON(for policy: ExtensionWebContentNetworkPolicy) -> String? {
        guard policy.requiresNetworkRuleList else { return nil }

        let schemeAndCredentials = "^[a-z][a-z0-9+.-]*://(?:[^/@]*@)?"
        let loopbackFilters = [
            schemeAndCredentials + "(?:[^/.:]+\\.)*localhost\\.?[:/]",
            schemeAndCredentials + "127[0-9.]*[:/]",
            schemeAndCredentials + "0[:/]",
            schemeAndCredentials + "0\\.0\\.0\\.0[:/]",
            schemeAndCredentials + "2130706433[:/]",
            schemeAndCredentials + "0[0-7.]+[:/]",
            schemeAndCredentials + "0x7f[0-9a-fx.]*[:/]",
            schemeAndCredentials + "\\[[0:]*1\\][:/]",
            schemeAndCredentials + "\\[[0:]*ffff:127\\.[0-9.]+\\][:/]"
        ]
        var rules: [[String: Any]] = []
        if policy == .blocked || policy == .localhostOnly {
            for filter in ["^http://", "^https://", "^ws://", "^wss://"] {
                rules.append(rule(urlFilter: filter, action: "block"))
            }
        } else if policy == .remoteOnly {
            // Requiring TLS prevents a permitted public hostname from being DNS-rebound
            // to a typical plaintext loopback service.
            for filter in ["^http://", "^ws://"] {
                rules.append(rule(urlFilter: filter, action: "block"))
            }
        }
        if policy == .remoteOnly {
            rules.append(contentsOf: loopbackFilters.map { rule(urlFilter: $0, action: "block") })
        } else if policy == .localhostOnly {
            rules.append(contentsOf: loopbackFilters.map {
                rule(urlFilter: $0, action: "ignore-previous-rules")
            })
        }

        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else {
            assertionFailure("Static network content rules must be valid JSON")
            return nil
        }
        return json
    }

    static func isLoopbackHost(_ rawHost: String?) -> Bool {
        guard var host = rawHost?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }

        if host == "localhost" || host.hasSuffix(".localhost") {
            return true
        }
        if isIPv6LoopbackOrMappedLoopback(host) {
            return true
        }
        if let address = legacyIPv4Address(host) {
            return address == 0 || address >> 24 == 127
        }
        return false
    }

    private static func makeNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func isValidNonce(_ nonce: String) -> Bool {
        !nonce.isEmpty && nonce.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48 ... 57, 65 ... 90, 97 ... 122, 43, 47, 95, 45:
                return true
            default:
                return false
            }
        }
    }

    private static func sources(for policy: ExtensionWebContentNetworkPolicy) -> [String] {
        switch policy {
        case .blocked:
            return []
        case .localhostOnly:
            return [
                "http://localhost:*", "https://localhost:*", "ws://localhost:*", "wss://localhost:*",
                "http://*.localhost:*", "https://*.localhost:*", "ws://*.localhost:*", "wss://*.localhost:*",
                "http://127.0.0.1:*", "https://127.0.0.1:*", "ws://127.0.0.1:*", "wss://127.0.0.1:*",
                "http://[::1]:*", "https://[::1]:*", "ws://[::1]:*", "wss://[::1]:*"
            ]
        case .remoteOnly:
            return ["https:", "wss:"]
        case .remoteAndLocalhost:
            return ["http:", "https:", "ws:", "wss:"]
        }
    }

    private static func rule(urlFilter: String, action: String) -> [String: Any] {
        [
            "trigger": [
                "url-filter": urlFilter,
                "url-filter-is-case-sensitive": false
            ] as [String: Any],
            "action": ["type": action]
        ]
    }

    private static func legacyIPv4Address(_ host: String) -> UInt32? {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 4).contains(components.count),
              components.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        let values = components.compactMap(parseIPv4Component)
        guard values.count == components.count else { return nil }

        let address: UInt64
        switch values.count {
        case 1 where values[0] <= UInt64(UInt32.max):
            address = values[0]
        case 2 where values[0] <= 0xFF && values[1] <= 0xFF_FFFF:
            address = (values[0] << 24) | values[1]
        case 3 where values[0] <= 0xFF && values[1] <= 0xFF && values[2] <= 0xFFFF:
            address = (values[0] << 24) | (values[1] << 16) | values[2]
        case 4 where values.allSatisfy({ $0 <= 0xFF }):
            address = (values[0] << 24) | (values[1] << 16) | (values[2] << 8) | values[3]
        default:
            return nil
        }
        return UInt32(address)
    }

    private static func parseIPv4Component(_ component: Substring) -> UInt64? {
        if component.hasPrefix("0x") || component.hasPrefix("0X") {
            let digits = component.dropFirst(2)
            return digits.isEmpty ? nil : UInt64(digits, radix: 16)
        }
        if component.count > 1 && component.first == "0" {
            return UInt64(component, radix: 8)
        }
        return UInt64(component, radix: 10)
    }

    private static func isIPv6LoopbackOrMappedLoopback(_ host: String) -> Bool {
        let addressText = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        var address = in6_addr()
        guard addressText.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return false
        }
        return withUnsafeBytes(of: &address) { rawBuffer in
            let bytes = Array(rawBuffer)
            let isLoopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
            let isMappedLocal = bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 0xFF
                && bytes[11] == 0xFF
                && (bytes[12] == 127 || bytes[12] == 0)
            return isLoopback || isMappedLocal
        }
    }

    private enum NoncedTag: String {
        case script
        case style
    }

    private static func addingNonceToInlineScriptsAndStyles(in html: String, nonce: String) -> String {
        var output = ""
        output.reserveCapacity(html.utf8.count + 128)
        var cursor = html.startIndex

        while cursor < html.endIndex {
            guard let openingBracket = html[cursor...].firstIndex(of: "<") else {
                output.append(contentsOf: html[cursor...])
                break
            }
            output.append(contentsOf: html[cursor..<openingBracket])

            if html[openingBracket...].hasPrefix("<!--") {
                guard let commentEnd = html.range(of: "-->", range: openingBracket..<html.endIndex)?.upperBound else {
                    output.append(contentsOf: html[openingBracket...])
                    break
                }
                output.append(contentsOf: html[openingBracket..<commentEnd])
                cursor = commentEnd
                continue
            }

            guard let tagEnd = endOfTag(in: html, startingAt: openingBracket) else {
                output.append(contentsOf: html[openingBracket...])
                break
            }
            let afterTag = html.index(after: tagEnd)
            guard let tag = noncedOpeningTag(in: html, startingAt: openingBracket) else {
                output.append(contentsOf: html[openingBracket..<afterTag])
                cursor = afterTag
                continue
            }

            let nameEnd = html.index(openingBracket, offsetBy: tag.rawValue.count + 1)
            let hasExternalSource = tag == .script && tagHasExternalSource(
                in: html,
                attributesStart: nameEnd,
                tagEnd: tagEnd
            )
            if hasExternalSource {
                output.append(contentsOf: html[openingBracket..<afterTag])
            } else {
                output.append(contentsOf: html[openingBracket..<nameEnd])
                output.append(" nonce=\"\(nonce)\"")
                output.append(contentsOf: html[nameEnd..<afterTag])
            }

            guard let closingRange = closingTagRange(named: tag.rawValue, in: html, from: afterTag) else {
                output.append(contentsOf: html[afterTag...])
                break
            }
            output.append(contentsOf: html[afterTag..<closingRange.upperBound])
            cursor = closingRange.upperBound
        }
        return output
    }

    private static func noncedOpeningTag(in html: String, startingAt openingBracket: String.Index) -> NoncedTag? {
        let nameStart = html.index(after: openingBracket)
        guard nameStart < html.endIndex else { return nil }
        let firstCharacter = html[nameStart]
        guard firstCharacter != "/" && firstCharacter != "!" && firstCharacter != "?" else { return nil }

        for tag in [NoncedTag.script, .style] {
            guard let nameEnd = html.index(nameStart, offsetBy: tag.rawValue.count, limitedBy: html.endIndex),
                  html[nameStart..<nameEnd].lowercased() == tag.rawValue,
                  nameEnd < html.endIndex,
                  isTagDelimiter(html[nameEnd]) else {
                continue
            }
            return tag
        }
        return nil
    }

    private static func endOfTag(in html: String, startingAt openingBracket: String.Index) -> String.Index? {
        var index = html.index(after: openingBracket)
        var quote: Character?
        while index < html.endIndex {
            let character = html[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    private static func closingTagRange(
        named tagName: String,
        in html: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        let needle = "</\(tagName)"
        var searchStart = start
        while searchStart < html.endIndex,
              let nameRange = html.range(
                  of: needle,
                  options: [.caseInsensitive],
                  range: searchStart..<html.endIndex
              ) {
            let nameEnd = nameRange.upperBound
            if nameEnd < html.endIndex,
               isTagDelimiter(html[nameEnd]),
               let tagEnd = endOfTag(in: html, startingAt: nameRange.lowerBound) {
                return nameRange.lowerBound..<html.index(after: tagEnd)
            }
            searchStart = nameEnd
        }
        return nil
    }

    private static func tagHasExternalSource(
        in html: String,
        attributesStart: String.Index,
        tagEnd: String.Index
    ) -> Bool {
        var index = attributesStart
        while index < tagEnd {
            while index < tagEnd && (isASCIIWhitespace(html[index]) || html[index] == "/") {
                index = html.index(after: index)
            }
            guard index < tagEnd else { break }

            let nameStart = index
            while index < tagEnd,
                  !isASCIIWhitespace(html[index]),
                  html[index] != "=",
                  html[index] != "/" {
                index = html.index(after: index)
            }
            guard nameStart < index else {
                index = html.index(after: index)
                continue
            }
            let attributeName = html[nameStart..<index].lowercased()
            if attributeName == "src" || attributeName == "href" || attributeName == "xlink:href" {
                return true
            }

            while index < tagEnd && isASCIIWhitespace(html[index]) {
                index = html.index(after: index)
            }
            guard index < tagEnd, html[index] == "=" else { continue }
            index = html.index(after: index)
            while index < tagEnd && isASCIIWhitespace(html[index]) {
                index = html.index(after: index)
            }
            guard index < tagEnd else { break }

            if html[index] == "\"" || html[index] == "'" {
                let quote = html[index]
                index = html.index(after: index)
                while index < tagEnd && html[index] != quote {
                    index = html.index(after: index)
                }
                if index < tagEnd {
                    index = html.index(after: index)
                }
            } else {
                while index < tagEnd && !isASCIIWhitespace(html[index]) && html[index] != "/" {
                    index = html.index(after: index)
                }
            }
        }
        return false
    }

    private static func isTagDelimiter(_ character: Character) -> Bool {
        isASCIIWhitespace(character) || character == "/" || character == ">"
    }

    private static func isASCIIWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r" || character == "\u{000C}"
    }
}
