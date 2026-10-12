import XCTest
import AppKit
@testable import KDXClientUI
import KDXCore

final class ClassicModelTests: XCTestCase {
    @MainActor func testSessionAndWindowIdentityIsolation() {
        let a = ClassicSession(endpoint:ClassicEndpoint()), b = ClassicSession(endpoint:ClassicEndpoint())
        XCTAssertFalse(a.client === b.client)
        XCTAssertNotEqual(ClassicWindowKey(session:a.id,kind:.chat(1)),ClassicWindowKey(session:b.id,kind:.chat(1)))
        a.drafts[.chat(1)] = "one"; a.drafts[.chat(2)] = "two"
        XCTAssertNil(b.drafts[.chat(1)]); XCTAssertEqual(a.drafts[.chat(2)],"two")
        a.disconnect(); XCTAssertEqual(a.drafts[.chat(1)],"one")
    }
    @MainActor func testPreferencesNeverSerializePasswordsAndRestoreIntoDisplays() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), suite = "kdx-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite)); defer { defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        let preferences = ClassicPreferences(root:root,defaults:defaults)
        let initial = try preferences.endpoints()
        XCTAssertEqual(initial,[.defaultTracker])
        XCTAssertEqual(try preferences.endpoints(),initial,"Reloading the built-in entry preserves its identity")
        XCTAssertEqual(initial.first?.host,"tracker.preterhuman.net")
        XCTAssertEqual(initial.first?.port,10800)
        XCTAssertEqual(initial.first?.tracker,true)
        XCTAssertEqual(initial.first?.login,"")
        try preferences.save(endpoints:[])
        XCTAssertTrue(try preferences.endpoints().isEmpty,"Deleting the default must persist")
        var endpoint = ClassicEndpoint(); endpoint.host = "localhost"; endpoint.login = "guest"
        try preferences.save(endpoints:[endpoint]); XCTAssertEqual(try preferences.endpoints(),[endpoint])
        let data = try String(contentsOf:root.appendingPathComponent("address-book.json"),encoding:.utf8)
        XCTAssertFalse(data.localizedCaseInsensitiveContains("password"))
        let screen = NSRect(x:-1440,y:0,width:1440,height:900), fallback = NSRect(x:0,y:0,width:500,height:400)
        preferences.save(frame:NSRect(x:8000,y:7000,width:600,height:500),key:"chat")
        let restored = preferences.frame(key:"chat",fallback:fallback,screens:[screen]); XCTAssertTrue(screen.contains(restored))
        XCTAssertEqual(restored.size,NSSize(width:600,height:500))
        XCTAssertTrue(screen.contains(ClassicPreferences.constrain(NSRect(x:0,y:0,width:5000,height:5000),to:[screen],fallback:fallback)))
    }
    @MainActor func testQueueStopWaitsForUnwindAndPreservesCapturedPaths() async throws {
        var continuations = [CheckedContinuation<Void,Error>](), started = [[String]](), active = 0, maximum = 0
        let queue = ClassicTransferQueue(perform: { item in
            active += 1; maximum = max(active,maximum); started.append(item.folder)
            defer { active -= 1 }
            try await withCheckedThrowingContinuation { continuations.append($0) }
        },cancel:{})
        let a = ClassicTransfer(folder:["original"],localURL:URL(fileURLWithPath:"/tmp/a"))
        let b = ClassicTransfer(folder:["second"],localURL:URL(fileURLWithPath:"/tmp/b"))
        let c = ClassicTransfer(folder:["third"],localURL:URL(fileURLWithPath:"/tmp/c"))
        queue.enqueue(a); queue.enqueue(b); queue.enqueue(c)
        for _ in 0..<100 where continuations.isEmpty { await Task.yield() }
        XCTAssertEqual(started,[["original"]]); queue.stop(a); queue.retry(a)
        XCTAssertEqual(a.state,.stopping); XCTAssertEqual(queue.activeID,a.id)
        queue.move(c,by:-1); continuations.removeFirst().resume(throwing:CancellationError())
        for _ in 0..<100 where started.count < 2 { await Task.yield() }
        XCTAssertEqual(a.state,.stopped); XCTAssertEqual(started,[["original"],["third"]]); XCTAssertEqual(maximum,1)
        queue.pauseAll(); continuations.removeFirst().resume(throwing:CancellationError())
        for _ in 0..<100 where queue.activeID != nil { await Task.yield() }
        XCTAssertEqual(b.state,.stopped); queue.retry(a)
        for _ in 0..<100 where started.count < 3 { await Task.yield() }
        XCTAssertEqual(started.last,["original"])
        continuations.removeFirst().resume()
        for _ in 0..<100 where queue.activeID != nil { await Task.yield() }
        XCTAssertEqual(a.state,.complete); queue.clearCompleted(); XCTAssertFalse(queue.items.contains { $0.id == a.id })
    }
    @MainActor func testObserverStopsAndDoesNotRetainOwner() async {
        let session = ClassicSession(endpoint:ClassicEndpoint()); var calls = 0
        let observation = ClassicObservation(); observation.start { _ = session.error; calls += 1 }
        session.error = "first"; for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls,2)
        observation.stop(); session.error = "second"; for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls,2)
    }
}
