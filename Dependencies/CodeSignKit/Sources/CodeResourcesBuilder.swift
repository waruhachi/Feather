//
//  CodeResourcesBuilder.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//


import Foundation
import Crypto

public final class CodeResourcesBuilder {


    private let bundleURL: URL
    private let executableName: String?
    private let rules: [String: any Sendable]
    private let rules2: [String: any Sendable]

    public init(
        bundleURL: URL,
        executableName: String?,
        rules: [String: any Sendable] = Constants.defaultCodeResourcesRules,
        rules2: [String: any Sendable] = Constants.defaultCodeResourcesRules2
    ) {
        self.bundleURL = bundleURL
        self.executableName = executableName
        self.rules = rules
        self.rules2 = rules2
    }

    public func build() throws -> Data {
        var files: [String: any Sendable] = [:]
        var files2: [String: [String: any Sendable]] = [:]

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: []
        ) else {
            throw CodeSignerError.ioError("Failed to enumerate bundle at \(bundleURL.path)")
        }

        let canonicalBundleURL = bundleURL.resolvingSymlinksInPath()
        let bundlePath = canonicalBundleURL.path
        let bundlePathPrefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"

        struct FileEntry {
            let relativePath: String
            let url: URL
        }

        var candidateFiles: [FileEntry] = []

        for case let fileURL as URL in enumerator {
            let canonicalFileURL = fileURL.resolvingSymlinksInPath()
            let standardized = canonicalFileURL.path
            guard standardized.hasPrefix(bundlePathPrefix) else { continue }
            let relativePath = String(standardized.dropFirst(bundlePathPrefix.count))

            // Ignore the current bundle's own _CodeSignature directory
            if relativePath == "_CodeSignature" || relativePath.hasPrefix("_CodeSignature/") {
                continue
            }

            // Check if directory
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if resourceValues?.isDirectory == true {
                continue
            }

            // Check if executable itself
            if let executableName = executableName, relativePath == executableName {
                continue
            }

            candidateFiles.append(FileEntry(relativePath: relativePath, url: fileURL))
        }

        struct HashResult {
            let relativePath: String
            let sha1: Data
            let sha256: Data
        }

        var hashResults = [HashResult?](repeating: nil, count: candidateFiles.count)

        DispatchQueue.concurrentPerform(iterations: candidateFiles.count) { i in
            let item = candidateFiles[i]
            let fileData = (try? Data(contentsOf: item.url, options: .alwaysMapped)) ?? (try? Data(contentsOf: item.url)) ?? Data()
            let sha1 = Data(Insecure.SHA1.hash(data: fileData))
            let sha256 = Data(SHA256.hash(data: fileData))
            hashResults[i] = HashResult(relativePath: item.relativePath, sha1: sha1, sha256: sha256)
        }

        let compiledRules = rules.compactMap { CompiledRule(pattern: $0.key, config: $0.value) }
        let compiledRules2 = rules2.compactMap { CompiledRule(pattern: $0.key, config: $0.value) }

        for result in hashResults.compactMap({ $0 }) {
            let eval1 = Self.evaluate(path: result.relativePath, against: compiledRules)
            if !eval1.omit {
                if eval1.optional {
                    files[result.relativePath] = [
                        "hash": result.sha1,
                        "optional": true
                    ]
                } else {
                    files[result.relativePath] = result.sha1
                }
            }

            let eval2 = Self.evaluate(path: result.relativePath, against: compiledRules2)
            if !eval2.omit {
                var entry: [String: any Sendable] = [
                    "hash2": result.sha256
                ]
                if eval2.optional {
                    entry["optional"] = true
                }
                files2[result.relativePath] = entry
            }
        }

        let plistDict: [String: any Sendable] = [
            "files" : files,
            "files2": files2,
            "rules" : rules,
            "rules2": rules2
        ]

        return try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
    }

    private struct CompiledRule {
        let pattern: String
        let regex: NSRegularExpression
        let weight: Double
        let omit: Bool
        let optional: Bool

        init?(pattern: String, config: any Sendable) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            self.pattern = pattern
            self.regex = regex

            if let dict = config as? [String: any Sendable] {
                self.weight = (dict["weight"] as? Double) ?? (dict["weight"] as? NSNumber)?.doubleValue ?? 1.0
                self.omit = (dict["omit"] as? Bool) ?? false
                self.optional = (dict["optional"] as? Bool) ?? false
            } else if let boolVal = config as? Bool {
                self.weight = 1.0
                self.omit = !boolVal
                self.optional = false
            } else {
                self.weight = 1.0
                self.omit = false
                self.optional = false
            }
        }

        func matches(_ path: String) -> Bool {
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            return regex.firstMatch(in: path, options: [], range: range) != nil
        }
    }

    private struct RuleEvaluation {
        let omit: Bool
        let optional: Bool
    }

    private static func evaluate(path: String, against rules: [CompiledRule]) -> RuleEvaluation {
        var bestWeight: Double = -Double.infinity
        var winningRule: CompiledRule?

        for rule in rules {
            if rule.matches(path) {
                if rule.weight > bestWeight {
                    bestWeight = rule.weight
                    winningRule = rule
                }
            }
        }

        guard let winner = winningRule else {
            return RuleEvaluation(omit: false, optional: false)
        }
        return RuleEvaluation(omit: winner.omit, optional: winner.optional)
    }
}

