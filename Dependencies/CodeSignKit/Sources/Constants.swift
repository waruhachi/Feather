//
//  Constants.swift
//  CodeSignKit
//
//  Created by Magesh K on 03/09/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Foundation

public enum Constants {
    // Recognized bundle directory extensions across iOS, iPadOS, macOS, watchOS, and tvOS
    public static let bundleExtensions: Set<String> = [
        "app", 
        "appex", 
        "framework", 
        "bundle", 
        "xpc", 
        "xctest", 
        "octest",
        "systemextension", 
        "plugin", 
        "mdimporter", 
        "qlgenerator", 
        "action", 
        "prefpane", 
        "kext"
    ]

    // Extensions representing framework, static/dynamic bundle, or kext containers
    public static let frameworkBundleExtensions: Set<String> = [
        "framework", 
        "bundle", 
        "kext"
    ]

    // Dynamic library and loose Mach-O binary extensions
    public static let dynamicLibraryExtensions: Set<String> = [
        "dylib", 
        "so"
    ]

    // Default code signing resource rules for v1 (files)
    public static let defaultCodeResourcesRules: [String: any Sendable] = [
        "^.*": true,
        "^.*\\.lproj/": [
            "optional": true,
            "weight": 1000.0
        ],
        "^.*\\.lproj/locversion.plist$": [
            "omit": true,
            "weight": 1100.0
        ],
        "^Base\\.lproj/": [
            "weight": 1010.0
        ],
        "^version.plist$": true
    ]

    // Default code signing resource rules for v2 (files2)
    public static let defaultCodeResourcesRules2: [String: any Sendable] = [
        ".*\\.dSYM($|/)": [
            "weight": 11.0
        ],
        "^(.*/)?\\.DS_Store$": [
            "omit": true,
            "weight": 2000.0
        ],
        "^.*": true,
        "^.*\\.lproj/": [
            "optional": true,
            "weight": 1000.0
        ],
        "^.*\\.lproj/locversion.plist$": [
            "omit": true,
            "weight": 1100.0
        ],
        "^Base\\.lproj/": [
            "weight": 1010.0
        ],
        "^Info\\.plist$": [
            "omit": true,
            "weight": 20.0
        ],
        "^PkgInfo$": [
            "omit": true,
            "weight": 20.0
        ],
        "^embedded\\.provisionprofile$": [
            "weight": 20.0
        ],
        "^version\\.plist$": [
            "weight": 20.0
        ]
    ]
}
