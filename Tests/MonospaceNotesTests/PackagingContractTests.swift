//
//  PackagingContractTests.swift
//  MonospaceNotesTests
//
//  TASK-15-PACKAGING focused suite — owner OWN-PACKAGING.
//
//  Covers CON-PACKAGING-RELEASE and CON-SECURITY-BOUNDARY: the packaging script
//  is the sole authority and carries no network command, the bundle identity in
//  Resources/Info.plist is exactly the locked identity, the entitlements file is
//  an empty dictionary with no sandbox key, and Resources/AppIcon.icns is a real
//  ICNS (magic header, non-trivial size) rather than a placeholder.
//
//  Swift Testing only: no XCTest, no placeholder assertions, no skips, and no
//  wall-clock windows.
//

import Foundation
import Testing

@testable import MonospaceNotes

@Suite("Packaging contract")
struct PackagingContractTests {

    /// Tests/MonospaceNotesTests/PackagingContractTests.swift -> up three levels = package root.
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let scriptPath = "Scripts/package_app.sh"
    static let infoPlistPath = "Resources/Info.plist"
    static let entitlementsPath = "Resources/App.entitlements"
    static let iconPath = "Resources/AppIcon.icns"
    static let appBundlePath = "dist/Monospace Notes.app"

    /// The ICNS container magic, and the four big-endian bytes that must open the file.
    static let icnsMagic: [UInt8] = [0x69, 0x63, 0x6E, 0x73]

    // MARK: - Helpers

    static func fileURL(_ relativePath: String) -> URL {
        packageRoot.appendingPathComponent(relativePath)
    }

    static func text(at relativePath: String) throws -> String {
        String(decoding: try Data(contentsOf: fileURL(relativePath)), as: UTF8.self)
    }

    /// Parses a plist with PropertyListSerialization and requires a dictionary root.
    static func plistDictionary(at relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL(relativePath))
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            Issue.record("\(relativePath) must parse as a plist dictionary")
            return [:]
        }
        return dictionary
    }

    static func stringValue(_ dictionary: [String: Any], _ key: String) -> String? {
        dictionary[key] as? String
    }

    // MARK: - The script

    @Test("The packaging script exists at the locked path, is executable, and is fail-fast")
    func packagingScriptIsPresentAndExecutable() throws {
        let url = Self.fileURL(Self.scriptPath)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
        #expect(exists, "Missing packaging authority at \(Self.scriptPath)")
        #expect(!isDirectory.boolValue, "\(Self.scriptPath) must be a regular file")
        #expect(
            FileManager.default.isExecutableFile(atPath: url.path),
            "\(Self.scriptPath) must be executable (chmod +x)"
        )

        let script = try Self.text(at: Self.scriptPath)
        #expect(script.hasPrefix("#!/bin/bash"),
                "The packaging authority must declare its shell interpreter")
        #expect(script.contains("set -euo pipefail"),
                "The packaging authority must run fail-fast under set -euo pipefail")
        #expect(script.contains("exit 1"),
                "Every rejected packaging step must exit non-zero")
        #expect(script.contains("die()") || script.contains("die ()"),
                "The script must have an explicit non-zero failure path")
    }

    @Test("The packaging script contains no network command and never installs")
    func packagingScriptContainsNoNetworkCommand() throws {
        let script = try Self.text(at: Self.scriptPath)

        for token in ["curl", "wget", "git clone", "URLSession", "NSURLConnection", "CFNetwork"] {
            #expect(!script.contains(token),
                    "The packaging authority must not contain the network token '\(token)'")
        }
        #expect(!script.contains("http://"), "No HTTP URL may appear in the packaging authority")
        #expect(!script.contains("https://"), "No HTTPS URL may appear in the packaging authority")
        #expect(!script.contains("/Applications"),
                "Packaging must not install: installation is a separate approved step")
        #expect(!script.contains("open "),
                "Packaging must not launch the bundle (no LaunchServices call)")
    }

    @Test("The packaging script is the sole authority for every release gate")
    func packagingScriptOwnsEveryReleaseGate() throws {
        let script = try Self.text(at: Self.scriptPath)

        let requiredInvocations = [
            "swift build -c release --arch arm64",     // release build
            "lipo -archs",                             // arm64 rejection
            "arm64",                                   // the accepted architecture
            "Resources/Info.plist",                    // identity source
            "Resources/App.entitlements",              // the only entitlements source
            "Resources/AppIcon.icns",                  // the single icon source
            "Contents/MacOS/MonospaceNotes",           // app assembly, verified path
            "Contents/Resources/AppIcon.icns",         // resource copy, verified path
            "Contents/Info.plist",                     // identity copied into the bundle
            "codesign --force --options runtime",      // single signing pass
            "codesign --verify --deep --strict",       // strict verification gate
            "hdiutil create",                          // DMG creation
            "hdiutil verify",                          // DMG verification
            "$REPO_ROOT/dist",                         // the declared output location
        ]
        for invocation in requiredInvocations {
            #expect(script.contains(invocation),
                    "The packaging authority must perform '\(invocation)'")
        }

        // No competing packaging implementation may exist.
        let competing = Self.fileURL("Sources/MonospaceNotes/Packaging.swift")
        #expect(!FileManager.default.fileExists(atPath: competing.path),
                "Sources/MonospaceNotes/Packaging.swift must not exist (script is the sole authority)")
    }

    // MARK: - Info.plist

    @Test("Resources/Info.plist declares exactly the locked bundle identity")
    func infoPlistDeclaresLockedIdentity() throws {
        let url = Self.fileURL(Self.infoPlistPath)
        #expect(FileManager.default.fileExists(atPath: url.path),
                "Missing \(Self.infoPlistPath)")

        let plist = try Self.plistDictionary(at: Self.infoPlistPath)

        #expect(Self.stringValue(plist, "CFBundleIdentifier") == "com.monospace.notes")
        #expect(Self.stringValue(plist, "CFBundleName") == "Monospace Notes")
        #expect(Self.stringValue(plist, "CFBundleExecutable") == "MonospaceNotes")
        #expect(Self.stringValue(plist, "CFBundleIconFile") == "AppIcon")
        #expect(Self.stringValue(plist, "CFBundlePackageType") == "APPL")
        #expect(Self.stringValue(plist, "CFBundleShortVersionString") == "1.0.0")
        #expect(Self.stringValue(plist, "CFBundleVersion") == "1")
        // Matches Package.swift platforms: [.macOS(.v14)], the floor for @Observable.
        #expect(Self.stringValue(plist, "LSMinimumSystemVersion") == "14.0")
        #expect(plist["NSHighResolutionCapable"] as? Bool == true)
        #expect(plist["LSUIElement"] as? Bool == false)
    }

    @Test("The bundle id in Resources/Info.plist equals LockedIdentity.bundleIdentifier")
    func infoPlistBundleIDMatchesLockedIdentity() throws {
        let plist = try Self.plistDictionary(at: Self.infoPlistPath)
        let declared = Self.stringValue(plist, "CFBundleIdentifier")

        #expect(declared == LockedIdentity.bundleIdentifier,
                "Info.plist bundle id must equal LockedIdentity.bundleIdentifier")
        #expect(declared == "com.monospace.notes")
        #expect(Self.stringValue(plist, "CFBundleName") == LockedIdentity.bundleName)
        #expect(Self.stringValue(plist, "CFBundleExecutable") == LockedIdentity.executableName)
        #expect(Self.stringValue(plist, "CFBundleIconFile") == LockedIdentity.iconName)
        #expect(Self.stringValue(plist, "CFBundleShortVersionString") == LockedIdentity.shortVersion)
        #expect(Self.stringValue(plist, "CFBundleVersion") == LockedIdentity.buildVersion)
        #expect(Self.stringValue(plist, "LSMinimumSystemVersion") == LockedIdentity.minimumSystemVersion)
    }

    // MARK: - Entitlements

    @Test("Resources/App.entitlements is an empty dictionary with no sandbox key")
    func entitlementsAreAnEmptyDictionary() throws {
        let url = Self.fileURL(Self.entitlementsPath)
        #expect(FileManager.default.fileExists(atPath: url.path),
                "Missing \(Self.entitlementsPath)")

        let entitlements = try Self.plistDictionary(at: Self.entitlementsPath)
        #expect(entitlements.isEmpty,
                "The local unsandboxed build signs with an empty entitlements dictionary")
        #expect(entitlements["com.apple.security.app-sandbox"] == nil,
                "com.apple.security.app-sandbox must be absent")

        let raw = try Self.text(at: Self.entitlementsPath)
        #expect(!raw.contains("com.apple.security"),
                "No com.apple.security.* entitlement may be declared")
        #expect(!raw.contains("com.apple.security.files.user-selected.read-write"),
                "No broad file entitlement may be declared")
        #expect(!raw.contains("com.apple.security.automation"),
                "No automation entitlement may be declared")
        #expect(raw.contains("<plist"), "The entitlements source must be an XML plist")
    }

    // MARK: - Icon

    @Test("Resources/AppIcon.icns is a real, non-trivial ICNS file")
    func appIconIsARealICNS() throws {
        let url = Self.fileURL(Self.iconPath)
        #expect(FileManager.default.fileExists(atPath: url.path),
                "Missing \(Self.iconPath)")

        let data = try Data(contentsOf: url)
        #expect(data.count > 10_000,
                "The icon must be a rendered ICNS, not a placeholder (\(data.count) bytes)")
        #expect(data.count >= 4)
        #expect(Array(data.prefix(4)) == Self.icnsMagic,
                "AppIcon.icns must begin with the ICNS magic header 'icns'")

        // The header's declared container length must match the real file size.
        let declaredLength = data.prefix(8).suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(Int(declaredLength) == data.count,
                "The ICNS header length (\(declaredLength)) must equal the file size (\(data.count))")
    }

    // MARK: - Assembled artifact

    @Test("The packaged artifact path is the locked one")
    func packagedArtifactPathIsLocked() {
        #expect(LockedIdentity.artifactPath == Self.appBundlePath,
                "The packaged artifact path must match LockedIdentity.artifactPath")
        #expect(Self.appBundlePath == "dist/Monospace Notes.app")
        #expect(LockedIdentity.bundleIdentifier == "com.monospace.notes")
        #expect(LockedIdentity.bundleName == "Monospace Notes")
        #expect(LockedIdentity.executableName == "MonospaceNotes")
    }
}
