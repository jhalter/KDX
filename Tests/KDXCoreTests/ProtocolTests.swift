import XCTest
@testable import KDXCore

final class ProtocolTests: XCTestCase {
    func fixture(_ side: String) throws -> [UInt8] {
        Array(try Data(contentsOf: Bundle.module.url(forResource: "first-connect.\(side)", withExtension: "bin", subdirectory: "Fixtures")!))
    }
    func testTwofishKnownAnswer() {
        let cipher = Twofish(key: [UInt8](repeating: 0, count: 32))
        let plain = [UInt8](repeating: 0, count: 16)
        let expected: [UInt8] = [0x57,0xff,0x73,0x9d,0x4d,0xc9,0x2c,0x1b,0xd7,0xfc,0x01,0x70,0x0c,0xc8,0x21,0x6f]
        XCTAssertEqual(cipher.encrypt(plain), expected)
        XCTAssertEqual(cipher.decrypt(expected), plain)
    }
    func testCapturedHandshakesAndEverySessionByte() throws {
        let key = AccountKey(password: "lab-only-pw!1"), cipher = SessionCipher(key: AccountKey(password: "lab-only-pw!1"))
        let client = try fixture("c2s"), server = try fixture("s2c")
        let ch = try Hello(wire: client), sh = try Hello(wire: server)
        XCTAssertEqual(String(decoding: ch.name, as: UTF8.self), "admin")
        XCTAssertEqual(ch.version, 0x10); XCTAssertEqual(sh.version, 0x20)
        for (wire, peer) in [(client, sh), (server, ch)] {
            let len = try Hello.length(wire), hello = try Hello(wire: wire)
            XCTAssertEqual(try hello.encode(key: wire.u32(0)), Array(wire.prefix(len)))
            let proof = try Proof(wire: Array(wire[len..<len+44]))
            XCTAssertEqual(proof.auth, Proof.authentication(key: key, nonce: peer.nonce))
            XCTAssertEqual(try proof.encode(), Array(wire[len..<len+44]))
            var at = len + 44, kinds = [UInt32]()
            while at < wire.count {
                let header = try cipher.header(Array(wire[at..<at+16]), limit: 0x100000)
                let end = at + 16 + header.paddedLength
                let message = try cipher.open(header, payload: Array(wire[at+16..<end]))
                XCTAssertEqual(try cipher.seal(message), Array(wire[at..<end]))
                kinds.append(message.type); at = end
            }
            XCTAssertEqual(at, wire.count); XCTAssertFalse(kinds.isEmpty)
        }
    }
    func testRejectsMalformedInputsAndIncorrectProof() throws {
        XCTAssertThrowsError(try Hello(wire: [0,1]))
        XCTAssertThrowsError(try ChallengeTable(data: Data(repeating: 0, count: 1739)))
        let nonce = [UInt8](repeating: 1, count: 12), response = [UInt8](repeating: 4, count: 20)
        let proof = Proof(key: AccountKey(password: "right"), nonce: nonce, response: response)
        XCTAssertThrowsError(try proof.verify(key: AccountKey(password: "wrong"), nonce: nonce, response: response))
        let cipher = SessionCipher(key: AccountKey(password: "pw"))
        let wire = try cipher.seal(Message(type: 100, payload: [UInt8](repeating: 1, count: 17)))
        XCTAssertThrowsError(try cipher.header(Array(wire.prefix(16)), limit: 16))
        XCTAssertThrowsError(try cipher.open(cipher.header(Array(wire.prefix(16)), limit: 17), payload: [0]))
    }
}
