import Foundation

public struct NewsGroup: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let count: Int
    public var description: String = ""
    var time: UInt64 = 0
    static func encodeList(_ groups: [NewsGroup]) throws -> [UInt8] {
        var out = UInt32(groups.count).beBytes
        for group in groups {
            let name = try shortText(group.name), description = try shortText(group.description)
            guard group.count <= Int(UInt16.max), group.count >= 0 else { throw KDXError.invalid("Invalid news count.") }
            var b = [UInt8](repeating: 0, count: 24)
            b.put(group.time, at: 0); b.put(group.id, at: 8); b.put(UInt16(group.count), at: 16)
            b[22] = UInt8(name.count); b[23] = UInt8(description.count)
            out += b + name + description; out.pad(4)
        }
        return out
    }
    static func decodeList(_ b: [UInt8]) throws -> [NewsGroup] {
        try b.require(4); guard b.u32(0) <= UInt32(b.count / 24) else { throw KDXError.invalid("Invalid newsgroup count.") }
        var at = 4, groups = [NewsGroup]()
        for _ in 0..<b.u32(0) {
            try b.require(at+24); let n = Int(b[at+22]), d = Int(b[at+23]); try b.require(at+24+n+d)
            groups.append(NewsGroup(id: b.u32(at+8), name: b.text(at+24..<at+24+n), count: Int(b.u16(at+16)), description: b.text(at+24+n..<at+24+n+d), time: b.u64(at)))
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
        b.put(KDXTime.encode(date), at: 0); b.put(groupID, at: 8); b.put(id, at: 12)
        b.put(UInt16(body.count), at: 24); b[28] = UInt8(author.count); b[29] = UInt8(login.count); b[30] = UInt8(subject.count)
        b += author + login + subject + body; b.pad(4); return b
    }
    static func decode(_ b: [UInt8], at: Int = 0) throws -> (NewsPost, Int) {
        try b.require(at+32)
        let a = Int(b[at+28]), l = Int(b[at+29]), s = Int(b[at+30]), n = Int(b.u16(at+24)), text = at+32
        try b.require(text+a+l+s+n)
        return (NewsPost(id: b.u32(at+12), groupID: b.u32(at+8), date: KDXTime.decode(b.u64(at)), author: b.text(text..<text+a), login: b.text(text+a..<text+a+l), subject: b.text(text+a+l..<text+a+l+s), body: b.text(text+a+l+s..<text+a+l+s+n)), (32+a+l+s+n+3) & ~3)
    }
    static func decodeList(_ b: [UInt8]) throws -> [NewsPost] {
        try b.require(16); guard b.u32(12) <= UInt32(b.count / 32) else { throw KDXError.invalid("Invalid news count.") }
        var at = 16, posts = [NewsPost]()
        for _ in 0..<b.u32(12) { try b.require(at); let (post, used) = try decode(b, at: at); posts.append(post); at += min(used, b.count-at) }
        return posts
    }
}
final class NewsStore {
    private(set) var posts: [NewsPost] = []
    private(set) var groups: [NewsGroupInfo] = [.general]
    struct Archive: Codable { var groupID: UInt32; var name: String; var posts: [NewsPost] }
    private(set) var archives: [Archive] = []
    private let url: URL?
    private var nextGroupID: UInt32 = 2
    private var nextMessageIDs: [String: UInt32] = ["1": 1]
    private struct Saved: Codable {
        var archives: [Archive]?
        var nextID: UInt32
        var posts: [NewsPost]
        var groups: [NewsGroupInfo]?
        var nextGroupID: UInt32?
        var nextMessageIDs: [String: UInt32]?
    }
    init() { url = nil }
    init(url: URL?) throws {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
            archives = saved.archives ?? []
            posts = saved.posts; groups = saved.groups ?? [.general]
            nextGroupID = saved.nextGroupID ?? 2
            nextMessageIDs = saved.nextMessageIDs ?? ["1": saved.nextID]
            if saved.groups == nil {
                let size = try posts.reduce(0) { try $0 + $1.encode().count }
                guard size <= Int(UInt16.max) * 1024 else { throw KDXError.invalid("Stored news exceeds protocol limits.") }
                groups[0].sizeLimitKiB = UInt16(max(50, (size+1023)/1024))
                groups[0].time = posts.map { KDXTime.encode($0.date) }.max() ?? 0
            }
            let originalGroups = groups
            // Migrate old storage budgets without discarding any post.
            for index in groups.indices { groups[index].sizeLimitKiB = min(1024, max(4, groups[index].sizeLimitKiB)) }
            try validate(groups: groups, posts: posts, nextGroupID: nextGroupID, nextMessages: nextMessageIDs, checkBudget: false)
            var migrated = posts
            var archived = archives
            for group in groups { let split = try partition(migrated, group: group, archives: archived); migrated = split.posts; archived = split.archives }
            try validate(groups: groups, posts: migrated, nextGroupID: nextGroupID, nextMessages: nextMessageIDs)
            if originalGroups != groups || migrated.count != posts.count || saved.groups == nil {
                try persist(groups: groups, posts: migrated, nextGroupID: nextGroupID, nextMessages: nextMessageIDs, archives: archived)
            }
            posts = migrated; archives = archived
        }
    }
    func group(_ id: UInt32) throws -> NewsGroupInfo {
        guard var group = groups.first(where: { $0.id == id }) else { throw KDXError.remote(0x1000c) }
        group.messageCount = UInt16(posts.filter { $0.groupID == id }.count); return group
    }
    func saveGroup(_ value: NewsGroupInfo, creating: Bool) throws -> NewsGroupInfo {
        var value = value
        value.sizeLimitKiB = min(1024, max(4, value.sizeLimitKiB)); try value.validate()
        var candidates = groups, ids = nextMessageIDs, next = nextGroupID
        if creating {
            guard next > 0, next < UInt32.max else { throw KDXError.invalid("Newsgroup identifier limit reached.") }
            value.id = next; next += 1; value.time = 0; value.messageCount = 0
            candidates.append(value); ids[String(value.id)] = 1
        } else {
            guard let index = candidates.firstIndex(where: { $0.id == value.id }) else { throw KDXError.remote(0x1000c) }
            value.time = candidates[index].time; value.messageCount = 0; candidates[index] = value
        }
        // Archive older posts in the same atomic transaction as the active list.
        let split = try partition(posts, group: value, archives: archives), retained = split.posts
        try persist(groups: candidates, posts: retained, nextGroupID: next, nextMessages: ids, archives: split.archives)
        archives = split.archives; groups = candidates; posts = retained; nextGroupID = next; nextMessageIDs = ids
        return try group(value.id)
    }
    func deleteGroup(_ id: UInt32) throws {
        _ = try group(id)
        let candidates = groups.filter { $0.id != id }, retained = posts.filter { $0.groupID != id }
        var ids = nextMessageIDs; ids.removeValue(forKey: String(id))
        try persist(groups: candidates, posts: retained, nextGroupID: nextGroupID, nextMessages: ids)
        groups = candidates; posts = retained; nextMessageIDs = ids
    }
    func add(groupID: UInt32 = 1, author: String, login: String, subject: String, body: String) throws -> NewsPost {
        let definition = try group(groupID)
        guard subject.utf8.count <= 128, body.utf8.count <= 16384, !subject.isEmpty, !body.isEmpty else { throw KDXError.remote(0x1000a) }
        let next = nextMessageIDs[String(groupID)] ?? 1
        guard next > 0, next < UInt32.max else { throw KDXError.invalid("News identifier limit reached.") }
        let post = NewsPost(id: next, groupID: groupID, date: Date(), author: author, login: login, subject: subject, body: body)
        let split = try partition(posts + [post], group: definition, archives: archives), retained = split.posts
        var candidates = groups, ids = nextMessageIDs
        candidates[candidates.firstIndex { $0.id == groupID }!].time = KDXTime.encode(post.date)
        ids[String(groupID)] = next + 1
        try persist(groups: candidates, posts: retained, nextGroupID: nextGroupID, nextMessages: ids, archives: split.archives)
        archives = split.archives; groups = candidates; posts = retained; nextMessageIDs = ids; return post
    }
    func delete(groupID: UInt32 = 1, id: UInt32, login: String, admin: Bool) throws {
        guard let post = posts.first(where: { $0.groupID == groupID && $0.id == id }) else { throw KDXError.remote(0x1000c) }
        guard admin || (post.login == login && posts.last(where: { $0.groupID == groupID })?.id == id) else { throw KDXError.remote(0x10014) }
        let result = posts.filter { $0.groupID != groupID || $0.id != id }
        try persist(groups: groups, posts: result, nextGroupID: nextGroupID, nextMessages: nextMessageIDs); posts = result
    }
    private func partition(_ posts: [NewsPost], group: NewsGroupInfo, archives: [Archive]) throws -> (posts: [NewsPost], archives: [Archive]) {
        let inGroup = posts.filter { $0.groupID == group.id }
        let sizes = try inGroup.map { try $0.encode().count }
        var total = sizes.reduce(0,+), start = 0
        while (total > Int(group.sizeLimitKiB) * 1024 && inGroup.count-start > 1) || inGroup.count - start > Int(UInt16.max) { total -= sizes[start]; start += 1 }
        let removed = Set(inGroup.prefix(start).map(\.id))
        var archives = archives
        if start > 0 {
            if let index = archives.firstIndex(where: { $0.groupID == group.id }) { archives[index].name = group.name; archives[index].posts += inGroup.prefix(start) }
            else { archives.append(Archive(groupID: group.id, name: group.name, posts: Array(inGroup.prefix(start)))) }
        }
        return (posts.filter { $0.groupID != group.id || !removed.contains($0.id) }, archives)
    }
    private func validate(groups: [NewsGroupInfo], posts: [NewsPost], nextGroupID: UInt32, nextMessages: [String: UInt32], checkBudget: Bool = true) throws {
        guard groups.count <= 256, Set(groups.map(\.id)).count == groups.count, groups.allSatisfy({ $0.id > 0 && $0.id < nextGroupID }), posts.allSatisfy({ post in groups.contains { $0.id == post.groupID } }) else { throw KDXError.invalid("Invalid saved newsgroups.") }
        for group in groups {
            try group.validate()
            let members = posts.filter { $0.groupID == group.id }
            guard members.count <= Int(UInt16.max), members.allSatisfy({ $0.id > 0 }), Set(members.map(\.id)).count == members.count,
                  let next = nextMessages[String(group.id)], next > (members.map(\.id).max() ?? 0) else { throw KDXError.invalid("Invalid saved news identifiers.") }
            guard try !checkBudget || members.count <= 1 || members.reduce(0, { try $0 + $1.encode().count }) <= Int(group.sizeLimitKiB) * 1024 else { throw KDXError.invalid("Stored news exceeds its group limit.") }
        }
    }
    private func persist(groups: [NewsGroupInfo], posts: [NewsPost], nextGroupID: UInt32, nextMessages: [String: UInt32], archives: [Archive]? = nil) throws {
        try validate(groups: groups, posts: posts, nextGroupID: nextGroupID, nextMessages: nextMessages)
        if let url {
            let saved = Saved(archives: archives ?? self.archives, nextID: nextMessages["1"] ?? 1, posts: posts, groups: groups, nextGroupID: nextGroupID, nextMessageIDs: nextMessages)
            try JSONEncoder().encode(saved).write(to: url, options: .atomic)
        }
    }
}
