import Foundation
import XCTest
@testable import OsaurusCore

final class AppCatalogTests: XCTestCase {
    private let notes = CUAppCatalogEntry(
        url: URL(fileURLWithPath: "/System/Applications/Notes.app"),
        bundleIdentifier: "com.example.Notes", executableName: "NotesExecutable",
        displayNames: ["Notes", "Заметки", "Notizen", "メモ"]
    )

    func testLocalizedNamesAndCase() {
        for name in ["заметки", "ЗАМЕТКИ", "notizen", "NOTIZEN", "メモ", " notes "] {
            XCTAssertEqual(CUAppResolver.resolve(name, in: [notes]), notes, name)
        }
    }

    func testBundleExecutableAndExplicitPath() {
        for name in ["COM.EXAMPLE.NOTES", "notesexecutable", notes.url.path] {
            XCTAssertEqual(CUAppResolver.resolve(name, in: [notes]), notes, name)
        }
    }

    func testDiacriticsAndUnicodeNormalization() {
        let app = CUAppCatalogEntry(
            url: URL(fileURLWithPath: "/Applications/Editor.app"), bundleIdentifier: nil,
            executableName: nil, displayNames: ["Éditeur", "Bücher"]
        )
        for name in ["EDITEUR", "E\u{301}diteur", "bucher", "BÜCHER"] {
            XCTAssertEqual(CUAppResolver.resolve(name, in: [app]), app)
        }
    }

    func testExactMatchesOnly() {
        for name in ["", "note", "unknown", "Open заметки"] {
            XCTAssertNil(CUAppResolver.resolve(name, in: [notes]))
        }
    }

    func testDeterministicTieBreakAndIdentityPriority() {
        let other = CUAppCatalogEntry(
            url: URL(fileURLWithPath: "/Applications/Other.app"),
            bundleIdentifier: "a.example", executableName: nil,
            displayNames: ["Notes", "com.example.Notes"]
        )
        let duplicate = CUAppCatalogEntry(
            url: URL(fileURLWithPath: "/Applications/Notes.app"),
            bundleIdentifier: notes.bundleIdentifier, executableName: nil, displayNames: ["Notes"]
        )
        for catalog in [[notes, other], [other, notes]] {
            XCTAssertEqual(CUAppResolver.resolve("notes", in: catalog), other)
            XCTAssertEqual(CUAppResolver.resolve("com.example.notes", in: catalog), notes)
        }
        for catalog in [[notes, duplicate], [duplicate, notes]] {
            XCTAssertEqual(CUAppResolver.resolve("notes", in: catalog), duplicate)
        }
    }

    func testReadsEveryPreferredLocalizationFromBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        func writePlist(_ value: [String: Any], to url: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
        }
        try writePlist([
            "CFBundleIdentifier": "test.localized", "CFBundleName": "Example",
            "CFBundleExecutable": "ExampleBinary", "CFBundlePackageType": "APPL",
            "CFBundleLocalizations": ["en", "ru", "de", "ja"],
        ], to: contents.appendingPathComponent("Info.plist"))
        for (locale, name) in [("ru", "Заметки"), ("de", "Notizen"), ("ja", "メモ")] {
            let folder = contents.appendingPathComponent("Resources/\(locale).lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writePlist(["CFBundleDisplayName": name, "CFBundleName": "\(name) Alias"],
                           to: folder.appendingPathComponent("InfoPlist.strings"))
        }
        let entry = try XCTUnwrap(CUAppCatalogEntry.read(at: app, preferredLanguages: ["ru-RU", "de-DE", "ja-JP"]))
        for name in ["заметки", "notizen", "メモ", "Notizen Alias", "ExampleBinary", "TEST.LOCALIZED"] {
            XCTAssertEqual(CUAppResolver.resolve(name, in: [entry]), entry, name)
        }
    }

    func testReadsPreferredNamesFromLoctable() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.loctable", "CFBundleName": "Example"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let table = [
            "ru": ["CFBundleDisplayName": "Заметки"],
            "de": ["CFBundleName": "Notizen"],
            "ja": ["CFBundleDisplayName": "メモ"],
        ]
        try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0)
            .write(to: resources.appendingPathComponent("InfoPlist.loctable"))
        let entry = try XCTUnwrap(CUAppCatalogEntry.read(at: app, preferredLanguages: ["ru", "de", "ja"]))
        for name in ["заметки", "NOTIZEN", "メモ"] {
            XCTAssertEqual(CUAppResolver.resolve(name, in: [entry]), entry)
        }
    }
}
