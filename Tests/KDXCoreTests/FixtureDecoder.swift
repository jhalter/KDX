import XCTest
@testable import KDXCore

func capturedMessages(_ name: String, password: String = "lab-only-pw!1") throws -> [Message] {
    let cipher = SessionCipher(key: AccountKey(password: password))
    var result = [Message]()
    for side in ["c2s", "s2c"] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "\(name).\(side)", withExtension: "bin", subdirectory: "Fixtures"))
        let bytes = Array(try Data(contentsOf: url)); var at = try Hello.length(bytes) + 44
        while at < bytes.count {
            try bytes.require(at + 16)
            let header = try cipher.header(Array(bytes[at..<at+16]), limit: 0x100000), end = at+16+header.paddedLength
            try bytes.require(end)
            result.append(try cipher.open(header, payload: Array(bytes[at+16..<end]))); at = end
        }
    }
    return result
}
