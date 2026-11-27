//
//  CodeSigner.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//


import Foundation

public final class CodeSigner {

    public static func sign(
        appPath: String,
        keyData: Data,
        password: String = "",
        teamID: String? = nil,
        options: CodeSigningOptions = [],
        entitlementProvider: @escaping (String) -> String,
        progress: @escaping () -> Void
    ) throws {
        let appURL = URL(fileURLWithPath: appPath).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw CodeSignerError.invalidPath("App path does not exist: \(appPath)")
        }

        let cmsSigner = CMSSigner(p12Data: keyData, password: password)

        // 1. Collect all embedded frameworks, dylibs, and app extensions
        let embeddedItems = collectEmbeddedItems(in: appURL)

        // 2. Sign embedded frameworks and dylibs first
        for itemURL in embeddedItems.frameworksAndDylibs {
            try signItem(
                at: itemURL,
                relativeTo: appURL,
                customTeamID: teamID,
                cmsSigner: cmsSigner,
                options: options,
                entitlementProvider: entitlementProvider
            )
            progress()
        }

        // 3. Sign app extensions (PlugIns)
        for appexURL in embeddedItems.appExtensions {
            try signItem(
                at: appexURL,
                relativeTo: appURL,
                customTeamID: teamID,
                cmsSigner: cmsSigner,
                options: options,
                entitlementProvider: entitlementProvider
            )
            progress()
        }

        // 4. Sign main application bundle
        try signItem(
            at: appURL,
            relativeTo: appURL,
            customTeamID: teamID,
            cmsSigner: cmsSigner,
            options: options,
            entitlementProvider: entitlementProvider
        )
        progress()
    }

    public static func signAdHoc(
        appPath: String,
        options: CodeSigningOptions = .adHoc,
        entitlementProvider: @escaping (String) -> String = { _ in "" },
        progress: @escaping () -> Void = {}
    ) throws {
        let appURL = URL(fileURLWithPath: appPath).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw CodeSignerError.invalidPath("App path does not exist: \(appPath)")
        }

        let embeddedItems = collectEmbeddedItems(in: appURL)

        for itemURL in embeddedItems.frameworksAndDylibs {
            try signItem(
                at: itemURL,
                relativeTo: appURL,
                customTeamID: nil,
                cmsSigner: nil,
                options: options.union(.adHoc),
                entitlementProvider: entitlementProvider
            )
            progress()
        }

        for appexURL in embeddedItems.appExtensions {
            try signItem(
                at: appexURL,
                relativeTo: appURL,
                customTeamID: nil,
                cmsSigner: nil,
                options: options.union(.adHoc),
                entitlementProvider: entitlementProvider
            )
            progress()
        }

        try signItem(
            at: appURL,
            relativeTo: appURL,
            customTeamID: nil,
            cmsSigner: nil,
            options: options.union(.adHoc),
            entitlementProvider: entitlementProvider
        )
        progress()
    }

    public static func removeSignature(at url: URL, deep: Bool = true) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw CodeSignerError.invalidPath("Path does not exist: \(url.path)")
        }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true

        if isDir {
            // 1. Remove _CodeSignature directory from bundle
            let codeSigDir = url.appendingPathComponent("_CodeSignature")
            if fileManager.fileExists(atPath: codeSigDir.path) {
                try? fileManager.removeItem(at: codeSigDir)
            }
        }

        // 2. Strip signature from executable binary if present
        if let target = resolveTarget(at: url) {
            let execData = try Data(contentsOf: target.executableURL)
            let unsignedData = try MachOSigner.removeSignature(binaryData: execData)
            try unsignedData.write(to: target.executableURL, options: .atomic)
        }

        // 3. Deep remove from embedded items if requested
        if deep && isDir {
            let embedded = collectEmbeddedItems(in: url)
            for fwURL in embedded.frameworksAndDylibs {
                try removeSignature(at: fwURL, deep: true)
            }
            for appexURL in embedded.appExtensions {
                try removeSignature(at: appexURL, deep: true)
            }
        }
    }

    private static func resolveTarget(at url: URL) -> (bundleURL: URL?, executableURL: URL)? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true

        if isDir {
            guard let exec = MachOParser.findExecutable(at: url), MachOParser.isMachOBinary(at: exec) else {
                return nil
            }
            return (bundleURL: url, executableURL: exec)
        } else {
            guard MachOParser.isMachOBinary(at: url) else { return nil }
            return (bundleURL: nil, executableURL: url)
        }
    }

    private static func signItem(
        at url: URL,
        relativeTo rootURL: URL,
        customTeamID: String? = nil,
        cmsSigner: CMSSigner?,
        options: CodeSigningOptions = [],
        entitlementProvider: (String) -> String
    ) throws {
        guard let target = resolveTarget(at: url) else {
            // Pure resource bundle or non-binary file; contents are sealed into CodeResources
            return
        }

        let fileManager = FileManager.default
        let bundleURL = target.bundleURL?.resolvingSymlinksInPath()
        let executableURL = target.executableURL.resolvingSymlinksInPath()

        // Compute relative path from root
        let rootURLResolved = rootURL.resolvingSymlinksInPath()
        let urlResolved = url.resolvingSymlinksInPath()
        let rootPath = rootURLResolved.path.hasSuffix("/") ? rootURLResolved.path : rootURLResolved.path + "/"
        let relPath: String
        if urlResolved.path == rootURLResolved.path {
            relPath = ""
        } else if urlResolved.path.hasPrefix(rootPath) {
            relPath = String(urlResolved.path.dropFirst(rootPath.count))
        } else {
            relPath = urlResolved.lastPathComponent
        }

        // Read or build bundle resources
        var infoPlistData: Data? = nil
        var codeResourcesData: Data? = nil
        var bundleID = executableURL.lastPathComponent
        var teamID: String? = (customTeamID?.isEmpty == false) ? customTeamID : cmsSigner?.leafCertificate?.organizationalUnit

        if let bundleURL = bundleURL {
            let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")
            if let data = try? Data(contentsOf: infoPlistURL) {
                infoPlistData = data
                if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: any Sendable] {
                    if let id = plist["CFBundleIdentifier"] as? String {
                        bundleID = id
                    }
                }
            }

            // Generate _CodeSignature/CodeResources
            let resourcesBuilder = CodeResourcesBuilder(
                bundleURL: bundleURL,
                executableName: executableURL.lastPathComponent
            )
            let resData = try resourcesBuilder.build()
            codeResourcesData = resData

            // Write _CodeSignature/CodeResources to disk
            let codeSigDir = bundleURL.appendingPathComponent("_CodeSignature")
            try? fileManager.createDirectory(at: codeSigDir, withIntermediateDirectories: true)
            let codeResURL = codeSigDir.appendingPathComponent("CodeResources")
            try resData.write(to: codeResURL, options: .atomic)
        }

        // Query entitlements from provider
        let rawEntitlements = entitlementProvider(relPath)
        let entitlementsXML: String? = rawEntitlements.isEmpty ? nil : rawEntitlements

        // Extract Team ID from existing binary if still nil
        if (teamID == nil || teamID?.isEmpty == true), let parser = try? MachOParser(url: executableURL) {
            teamID = parser.teamID()
        }


        // Read executable data
        let binaryData = try Data(contentsOf: executableURL)

        // Sign Mach-O binary
        let machOSigner = MachOSigner(
            binaryData: binaryData,
            bundleIdentifier: bundleID,
            teamIdentifier: teamID,
            entitlementsXML: entitlementsXML,
            infoPlistData: infoPlistData,
            codeResourcesData: codeResourcesData,
            cmsSigner: cmsSigner,
            options: options
        )


        let signedBinary = try machOSigner.sign()

        // Write signed binary back to disk
        try signedBinary.write(to: executableURL, options: .atomic)

        // Ensure executable permissions (0755)
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }

    private struct EmbeddedItems {
        var frameworksAndDylibs: [URL] = []
        var appExtensions: [URL] = []
    }

    private static func collectEmbeddedItems(in appURL: URL) -> EmbeddedItems {
        var items = EmbeddedItems()
        let fileManager = FileManager.default
        var seenPaths = Set<String>()

        let canonicalAppURL = appURL.resolvingSymlinksInPath()
        let mainExecPath = MachOParser.findExecutable(at: canonicalAppURL)?.resolvingSymlinksInPath().path

        if let enumerator = fileManager.enumerator(
            at: canonicalAppURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent.hasPrefix(".") {
                    continue
                }

                let canonicalURL = fileURL.resolvingSymlinksInPath()
                let path = canonicalURL.path
                if path == canonicalAppURL.path || path == mainExecPath {
                    continue
                }

                let ext = fileURL.pathExtension.lowercased()
                let isDir = (try? canonicalURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true

                if isDir {
                    if Constants.bundleExtensions.contains(ext) {
                        if Constants.frameworkBundleExtensions.contains(ext) {
                            if seenPaths.insert(path).inserted {
                                items.frameworksAndDylibs.append(canonicalURL)
                            }
                        } else {
                            if seenPaths.insert(path).inserted {
                                items.appExtensions.append(canonicalURL)
                            }
                        }
                    }
                } else {
                    if Constants.dynamicLibraryExtensions.contains(ext) || MachOParser.isMachOBinary(at: canonicalURL) {
                        if seenPaths.insert(path).inserted {
                            items.frameworksAndDylibs.append(canonicalURL)
                        }
                    }
                }
            }
        }

        // Sort items bottom-up so that nested children are signed before their parent bundles
        items.frameworksAndDylibs.sort {
            $0.pathComponents.count > $1.pathComponents.count
        }
        items.appExtensions.sort {
            $0.pathComponents.count > $1.pathComponents.count
        }

        return items
    }
}
