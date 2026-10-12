import XCTest
import KDXCore
@testable import KDXClientUI

final class RemotePathQueueTests: XCTestCase {
    @MainActor func testQueueRetainsRawFolderBytesIndependentlyOfDisplayName() async throws {
        let first = RemotePath(components: [[0x63,0x61,0x66,0x8e]])
        let second = RemotePath(components: [[0x63,0x61,0x66,0x8f]])
        XCTAssertEqual(first.names, second.names)
        XCTAssertNotEqual(first, second)
        let item = ClassicTransfer(remoteFolder: first, localURL: URL(fileURLWithPath: "/tmp/upload.bin"))
        var observed: RemotePath?
        let queue = ClassicTransferQueue(perform: { observed = $0.remoteFolder }, cancel: {})
        queue.enqueue(item)
        for _ in 0..<100 where item.state != .complete { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(observed, first); XCTAssertNotEqual(observed, second)
        XCTAssertEqual(item.folder, first.names)
    }
}
