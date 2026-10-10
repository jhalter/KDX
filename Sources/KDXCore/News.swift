import Foundation

public struct NewsGroup: Identifiable, Sendable {
    public let id: UInt32
    public let name: String
    public let count: Int
    static func decodeList(_ b: [UInt8]) throws -> [NewsGroup] {
        try b.require(4); guard b.u32(0) <= UInt32(b.count / 24) else { throw KDXError.invalid("Invalid newsgroup count.") }
        var at = 4, groups = [NewsGroup]()
        for _ in 0..<b.u32(0) {
            try b.require(at+24); let n = Int(b[at+22]), d = Int(b[at+23]); try b.require(at+24+n+d)
            groups.append(NewsGroup(id: b.u32(at+8), name: b.text(at+24..<at+24+n), count: Int(b.u16(at+16))))
            at += min((24+n+d+3) & ~3, b.count-at)
        }
        return groups
    }
}
public struct NewsPost: Codable, Identifiable, Sendable {
    public var id: UInt32
    public var groupID: UInt32 = 1
    public var date: Date
    public var author: String
    public var login: String
    public var subject: String
    public var body: String
    func encode() throws -> [UInt8] {
        let author = try shortText(author), login = try shortText(login), subject = try shortText(subject), body = Array(body.utf8)
        guard body.count <= 65535 else { throw KDXError.invalid("News body exceeds protocol limits.") }
        var b = [UInt8](repeating: 0, count: 32)
        b.put(UInt64(max(0, date.timeIntervalSince1970 * 1000)), at: 0); b.put(groupID, at: 8); b.put(id, at: 12)
        b.put(UInt16(body.count), at: 24); b[28] = UInt8(author.count); b[29] = UInt8(login.count); b[30] = UInt8(subject.count)
        b += author + login + subject + body; b.pad(4); return b
    }
    static func decode(_ b: [UInt8]) throws -> (NewsPost, Int) {
        try b.require(32)
        let a = Int(b[28]), l = Int(b[29]), s = Int(b[30]), n = Int(b.u16(24)); try b.require(32+a+l+s+n)
        return (NewsPost(id: b.u32(12), groupID: b.u32(8), date: Date(timeIntervalSince1970: Double(b.u64(0))/1000), author: b.text(32..<32+a), login: b.text(32+a..<32+a+l), subject: b.text(32+a+l..<32+a+l+s), body: b.text(32+a+l+s..<32+a+l+s+n)), (32+a+l+s+n+3) & ~3)
    }
    static func decodeList(_ b: [UInt8]) throws -> [NewsPost] {
        try b.require(16); guard b.u32(12) <= UInt32(b.count / 32) else { throw KDXError.invalid("Invalid news count.") }
        var at = 16, posts = [NewsPost]()
        for _ in 0..<b.u32(12) { try b.require(at); let (post, used) = try decode(Array(b[at...])); posts.append(post); at += min(used, b.count-at) }
        return posts
    }
}
final class NewsStore {
    private(set) var posts: [NewsPost] = []
    private let url: URL?
    private var nextID: UInt32 = 1
    private struct Saved: Codable { let nextID: UInt32; let posts: [NewsPost] }
    init() { url = nil }
    init(url: URL?) throws {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
            posts = saved.posts; nextID = saved.nextID
        }
    }
    func add(author: String, login: String, subject: String, body: String) throws -> NewsPost {
        guard subject.utf8.count <= 128, body.utf8.count <= 16384, !subject.isEmpty, !body.isEmpty, posts.count < 1000 else { throw KDXError.remote(0x1000a) }
        let next = nextID
        guard next != 0, next != UInt32.max else { throw KDXError.invalid("News identifier limit reached.") }
        let post = NewsPost(id: next, date: Date(), author: author, login: login, subject: subject, body: body)
        try persist(posts + [post], nextID: next + 1); nextID = next + 1; posts.append(post); return post
    }
    func delete(id: UInt32, login: String, admin: Bool) throws {
        guard let post = posts.first(where: { $0.id == id }) else { throw KDXError.remote(0x1000c) }
        guard admin || post.login == login else { throw KDXError.remote(0x10014) }
        let result = posts.filter { $0.id != id }; try persist(result, nextID: nextID); posts = result
    }
    private func persist(_ posts: [NewsPost], nextID: UInt32) throws {
        if let url { try JSONEncoder().encode(Saved(nextID: nextID, posts: posts)).write(to: url, options: .atomic) }
    }
}
