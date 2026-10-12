import AppKit
import XCTest
@testable import KDXClientUI
@testable import KDXCore

final class ClassicTrackerWindowTests: XCTestCase {
    @MainActor private final class HeadlessTracker: TrackerWindow {
        var errors: [Error] = []
        override func showError(_ error: Error) { errors.append(error) }
    }
    @MainActor private func preferences() throws -> (ClassicPreferences,() -> Void) {
        _ = NSApplication.shared
        let suite = "KDX-tracker-window-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        return (ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults),{ defaults.removePersistentDomain(forName:suite) })
    }
    private func group(_ id: Int) -> TrackerGroup {
        TrackerGroup(id:id,serverCount:2,name:"Group \(id)",description:"",nameBytes:Array("Group \(id)".utf8))
    }
    private func server(_ id: Int, port: UInt16) -> TrackerServer {
        TrackerServer(id:id,name:"Same server name",description:"",host:"127.0.0.1",port:port,header:[UInt8](repeating:0,count:28),address:[],extra:[])
    }
    @MainActor private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("The window operation did not settle")
    }
    @MainActor func testSameHostPortsAndConnectionTargetsRemainIndependent() async throws {
        let (preferences,cleanup) = try preferences(); defer { cleanup() }
        let records = [server(0,port:10700),server(1,port:20700)]
        var selected: ClassicEndpoint?
        let window = HeadlessTracker(endpoint:ClassicEndpoint(),preferences:preferences,queries:ClassicTrackerQueries(groups:{ [self] in [group(0)] },servers:{ _ in records })) { selected = $0 }
        await settle { !window.groupRecords.isEmpty }
        window.groups.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        await settle { window.serverRecords.count == 2 }
        XCTAssertEqual(window.servers.rows.map { $0.values[2] },["127.0.0.1:10700","127.0.0.1:20700"])
        window.servers.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        window.servers.activate?(window.servers.visible[1])
        XCTAssertEqual(selected?.host,"127.0.0.1"); XCTAssertEqual(selected?.port,20700)
        XCTAssertTrue(window.errors.isEmpty); XCTAssertFalse(try XCTUnwrap(window.window).isVisible)
        window.requestClose()
    }
    @MainActor func testCancelAndRefreshRejectLateGroupsAndErrors() async throws {
        let (preferences,cleanup) = try preferences(); defer { cleanup() }
        var pending: [CheckedContinuation<[TrackerGroup],Error>] = []
        var cancellations: [Bool] = []
        let window = HeadlessTracker(endpoint:ClassicEndpoint(),preferences:preferences,queries:ClassicTrackerQueries(groups:{
            defer { cancellations.append(Task.isCancelled) }
            return try await withCheckedThrowingContinuation { pending.append($0) }
        },servers:{ _ in [] })) { _ in XCTFail("Queries must not connect") }
        await settle { pending.count == 1 }
        window.cancelQuery()
        pending.removeFirst().resume(returning:[group(0)])
        await settle { cancellations.count == 1 }
        XCTAssertEqual(cancellations,[true]); XCTAssertTrue(window.groupRecords.isEmpty)
        XCTAssertEqual(window.state.stringValue,"Cancelled")
        window.refresh(); await settle { pending.count == 1 }
        window.refresh(); await settle { pending.count == 2 }
        pending.removeFirst().resume(throwing:KDXError.invalid("Superseded"))
        pending.removeFirst().resume(returning:[group(1)])
        await settle { window.groupRecords.first?.id == 1 }
        XCTAssertEqual(window.groups.rows.map(\.id),["1"])
        XCTAssertEqual(window.state.stringValue,"Select a group.")
        XCTAssertTrue(window.errors.isEmpty); window.requestClose()
    }
    @MainActor func testGroupSwitchAndCloseDiscardPendingServers() async throws {
        let (preferences,cleanup) = try preferences(); defer { cleanup() }
        let groups = [group(0),group(1)]
        var pending: [(Int,CheckedContinuation<[TrackerServer],Error>)] = []
        var finished = 0
        let window = HeadlessTracker(endpoint:ClassicEndpoint(),preferences:preferences,queries:ClassicTrackerQueries(groups:{ groups },servers:{ group in
            defer { finished += 1 }
            return try await withCheckedThrowingContinuation { pending.append((group.id,$0)) }
        })) { _ in XCTFail("Queries must not connect") }
        await settle { window.groupRecords.count == 2 }
        window.load(groups[0]); await settle { pending.count == 1 }
        window.load(groups[1]); await settle { pending.count == 2 }
        XCTAssertEqual(pending.map(\.0),[0,1])
        pending.removeLast().1.resume(returning:[server(1,port:20700)])
        await settle { window.serverRecords.first?.id == 1 }
        pending.removeFirst().1.resume(returning:[server(0,port:10700)])
        await settle { finished == 2 }
        XCTAssertEqual(window.serverRecords.map(\.id),[1])
        window.load(groups[0]); await settle { pending.count == 1 }
        window.requestClose()
        pending.removeFirst().1.resume(returning:[server(0,port:10700)])
        await settle { finished == 3 }
        XCTAssertTrue(window.serverRecords.isEmpty); XCTAssertTrue(window.servers.rows.isEmpty)
        XCTAssertTrue(window.errors.isEmpty); XCTAssertFalse(try XCTUnwrap(window.window).isVisible)
    }
}
