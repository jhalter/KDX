import Foundation
import CryptoKit

extension ChallengeTable {
    // Pinned archive and digest from scottanderson/kdx's table.rs and vendor/MANIFEST.md.
    public static let downloadURL = URL(string: "https://web.archive.org/web/20051014065628id_/http://www.haxial.com:80/download/KDXTrackerServ1110-Win.zip")!
    static let archiveChecksum = "8f50ef0cd4f82fc5b071340932c498a9df3556ed6cff6f23ecd6c36c43683583"
    public static func download() async throws -> Self { try await download(session: .shared) }
    static func download(session: URLSession) async throws -> Self {
        try Task.checkCancellation()
        let request = URLRequest(url: downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw KDXError.invalid("The KDX archive could not be downloaded. You can import a local program or ZIP instead.") }
        guard response.expectedContentLength <= TableArchive.fileLimit else { throw KDXError.invalid("The downloaded archive exceeds the 32 MiB limit.") }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in stream {
            guard data.count < TableArchive.fileLimit else { throw KDXError.invalid("The downloaded archive exceeds the 32 MiB limit.") }
            data.append(byte)
            if data.count % 65536 == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return try verifiedDownload(data)
    }
    static func verifiedDownload(_ data: Data) throws -> Self {
        guard data.count <= TableArchive.fileLimit,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == archiveChecksum else {
            throw KDXError.invalid("The downloaded KDX archive checksum does not match the reference. Import a local KDX program or ZIP instead.")
        }
        return try Self(data: data)
    }
}
