import XCTest
import Darwin
@testable import KDXClientUI

@MainActor final class ArchiveImporterTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let archive: URL
        let temporary: URL
        var options: ArchiveImportOptions
        init(extractor: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("kdx-archive-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            temporary = root.appendingPathComponent("temporary")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            archive = root.appendingPathComponent("input.sit")
            try Data(#"{"lsarContents":[{"XADFileName":"skin.hap","XADFileSize":1}]}"#.utf8).write(to: archive)
            for (name, body) in [("lsar", "cat \"$2\""), ("unar", extractor)] {
                let path = root.appendingPathComponent(name)
                try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }
            options = ArchiveImportOptions(unar: root.appendingPathComponent("unar").path, lsar: root.appendingPathComponent("lsar").path, temporaryParent: temporary)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
    private let stubborn = "trap '' TERM; echo $$ > \"$6.pid\"; : > \"$6.started\"; while :; do :; done"
    private func assertClean(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path), [], file: file, line: line)
        let marker = fixture.archive.appendingPathExtension("pid")
        if FileManager.default.fileExists(atPath: marker.path) {
            let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertEqual(kill(pid, 0), -1, "Archive process is still alive", file: file, line: line)
            XCTAssertEqual(errno, ESRCH, file: file, line: line)
        }
    }
    private func waitForExtractor(_ fixture: Fixture) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: fixture.archive.appendingPathExtension("started").path) {
            guard ContinuousClock.now < deadline else { throw AppearanceError.invalid("Test extractor did not start.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func testInstalledToolsExtractHAPAndReferenceResourceForkWhenAvailable() throws {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin"]
        guard paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/unar") }),
              paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/lsar") }) else {
            throw XCTSkip("Install unar/lsar to verify installed-tool extraction.")
        }
        let fixture = try Fixture(extractor: "exit 0"); defer { fixture.clean() }
        let source = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try AppearanceTests().hap().write(to: source.appendingPathComponent("skin.hap"))
        var names = ["skin.hap"]
        var expected: AppearanceImport?
        if let reference = ProcessInfo.processInfo.environment["KDX_REFERENCE"] {
            let url = URL(fileURLWithPath: reference)
            try FileManager.default.copyItem(at: url, to: source.appendingPathComponent("KDXClient.app"))
            names.append("KDXClient.app")
            if FileManager.default.fileExists(atPath: url.appendingPathExtension("rsrc").path) {
                try FileManager.default.copyItem(at: url.appendingPathExtension("rsrc"), to: source.appendingPathComponent("KDXClient.app.rsrc"))
                names.append("KDXClient.app.rsrc")
            }
            expected = try ClassicAssetImporter.loadSync(url)
        }
        _ = try ArchiveProcess.run("/usr/bin/tar", arguments: ["-cf", fixture.archive.path, "-C", source.path] + names, directory: fixture.root)
        let result = try ClassicAssetImporter.loadSync(fixture.archive, options: ArchiveImportOptions(temporaryParent: fixture.temporary))
        XCTAssertEqual(result.appearances.count, 1 + (expected?.appearances.count ?? 0))
        XCTAssertTrue(result.appearances.contains { $0.name == "skin" })
        if let expected {
            for appearance in expected.appearances { XCTAssertTrue(result.appearances.contains(appearance)) }
            for (key, bytes) in expected.assets where key.hasPrefix("resource-") {
                XCTAssertTrue(result.assets.contains { $0.key.hasSuffix(key) && $0.value == bytes }, "Missing resource fork asset: \(key)")
            }
        }
        try assertClean(fixture)
    }
    func testNormalToolOutputAndNonzeroExit() throws {
        let fixture = try Fixture(extractor: "exit 0"); defer { fixture.clean() }
        let output = try ArchiveProcess.run("/bin/sh", arguments: ["-c", "printf listing"], directory: fixture.root)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "listing")
        XCTAssertThrowsError(try ArchiveProcess.run("/bin/sh", arguments: ["-c", "printf failed; exit 2"], directory: fixture.root))
        try assertClean(fixture)
    }
    func testOutputFloodHasBoundedMemoryAndStopsTool() throws {
        let fixture = try Fixture(extractor: "exit 0"); defer { fixture.clean() }
        let start = ContinuousClock.now
        XCTAssertThrowsError(try ArchiveProcess.run("/bin/sh", arguments: ["-c", "trap '' TERM; echo $$ > \"$1.pid\"; while :; do printf 0123456789; done", "test", fixture.archive.path], directory: fixture.root, outputLimit: 1024)) { error in
            XCTAssertTrue(error.localizedDescription.contains("output limit"))
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        try assertClean(fixture)
    }
    func testDeadlineKillsExtractorIgnoringTermination() throws {
        var fixture = try Fixture(extractor: stubborn); defer { fixture.clean() }
        fixture.options.processTimeout = 0.3
        let start = ContinuousClock.now
        XCTAssertThrowsError(try ClassicAssetImporter.loadSync(fixture.archive, options: fixture.options)) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        try assertClean(fixture)
    }
    func testParentCancellationAwaitsCleanupAndPreservesCatalog() async throws {
        let fixture = try Fixture(extractor: stubborn); defer { fixture.clean() }
        let library = AppearanceLibrary(root: fixture.root.appendingPathComponent("library"))
        let original = try AppearanceDecoder.hap(AppearanceTests().hap(), name: "Working")
        try library.install(original)
        let catalog = library.load()
        let task = Task {
            let imported = try await ClassicAssetImporter.load(fixture.archive, options: fixture.options)
            try Task.checkCancellation()
            try library.install(imported)
        }
        defer { task.cancel() }
        try await waitForExtractor(fixture)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled import succeeded") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)") }
        try assertClean(fixture)
        XCTAssertEqual(library.load(), catalog)
    }
    func testAlreadyCancelledCallerNeverStartsExtractor() async throws {
        let fixture = try Fixture(extractor: stubborn); defer { fixture.clean() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ClassicAssetImporter.load(fixture.archive, options: fixture.options)
        }
        do { _ = try await task.value; XCTFail("Cancelled import succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.archive.appendingPathExtension("started").path))
        try assertClean(fixture)
    }
    func testActualAggregateLimitOverridesFalseListing() throws {
        var fixture = try Fixture(extractor: "printf '%4096s' x > \"$5/a\"; printf '%4096s' x > \"$5/b\"; " + stubborn)
        defer { fixture.clean() }
        fixture.options.maximumBytes = 4096
        XCTAssertThrowsError(try ClassicAssetImporter.loadSync(fixture.archive, options: fixture.options)) { error in
            XCTAssertTrue(error.localizedDescription.contains("size limit"))
        }
        try assertClean(fixture)
    }
    func testFinalInspectionRejectsLinksSpecialFilesAndExcessEntries() throws {
        for script in ["ln -s \"$6\" \"$5/skin.hap\"", "mkfifo \"$5/skin.hap\"", "mkdir \"$5/a\" \"$5/b\" \"$5/c\""] {
            var fixture = try Fixture(extractor: script); defer { fixture.clean() }
            fixture.options.maximumEntries = 3
            XCTAssertThrowsError(try ClassicAssetImporter.loadSync(fixture.archive, options: fixture.options)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Unsafe archive output"))
            }
            try assertClean(fixture)
        }
    }
    func testNestedArchivesShareOneExtractionBudget() throws {
        // Each archive individually fits. Retained bytes across the outer and inner extraction do not.
        let script = """
        case "$6" in
          */input.sit) cp "$6" "$5/nested.sit"; printf '%3000s' x > "$5/outer.dat" ;;
          *) printf '%3000s' x > "$5/inner.dat" ;;
        esac
        """
        var fixture = try Fixture(extractor: script); defer { fixture.clean() }
        fixture.options.maximumBytes = 5000
        XCTAssertThrowsError(try ClassicAssetImporter.loadSync(fixture.archive, options: fixture.options)) { error in
            XCTAssertTrue(error.localizedDescription.contains("size limit"))
        }
        try assertClean(fixture)
    }
    func testDecodedAssetBudgetAndAppearanceCountAreCheckedBeforeInstall() throws {
        var fixture = try Fixture(extractor: "cp \"$6.fixture\" \"$5/skin.hap\""); defer { fixture.clean() }
        let hap = AppearanceTests().hap()
        try hap.write(to: fixture.archive.appendingPathExtension("fixture"))
        fixture.options.maximumBytes = hap.count + 1
        XCTAssertThrowsError(try ClassicAssetImporter.loadSync(fixture.archive, options: fixture.options)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Imported assets"))
        }
        try assertClean(fixture)
        let many = try Fixture(extractor: "i=0; while [ \"$i\" -lt 65 ]; do cp \"$6.fixture\" \"$5/skin-$i.hap\"; i=$((i+1)); done")
        defer { many.clean() }
        try hap.write(to: many.archive.appendingPathExtension("fixture"))
        XCTAssertThrowsError(try ClassicAssetImporter.loadSync(many.archive, options: many.options)) { error in
            XCTAssertTrue(error.localizedDescription.contains("count limit"))
        }
        try assertClean(many)
    }
    func testSuccessfulExtractionAndWholeImportDeadline() throws {
        var fixture = try Fixture(extractor: "cp \"$6.fixture\" \"$5/skin.hap\""); defer { fixture.clean() }
        try AppearanceTests().hap().write(to: fixture.archive.appendingPathExtension("fixture"))
        let result = try ClassicAssetImporter.loadSync(fixture.archive, options: fixture.options)
        XCTAssertEqual(result.appearances.map(\.name), ["skin"])
        XCTAssertEqual(result.appearances[0].colors[7], 0x070707)
        try assertClean(fixture)
        fixture.options.totalTimeout = 0
        XCTAssertThrowsError(try ClassicAssetImporter.loadSync(fixture.archive, options: fixture.options)) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        try assertClean(fixture)
    }
}
