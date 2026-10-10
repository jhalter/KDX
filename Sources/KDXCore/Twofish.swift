// Swift adaptation of RustCrypto Twofish (MIT); see Notices/RustCrypto-MIT.txt.
import Foundation

struct Twofish: Sendable {
    private let keys: [UInt32]
    private let tables: [[UInt32]]
    private static let order = [[1,1,0,0,1], [0,1,1,0,0], [0,0,0,1,1], [1,0,1,1,0]]
    private static let q: [[[UInt8]]] = [
        [[8,1,7,13,6,15,3,2,0,11,5,9,14,12,10,4], [14,12,11,8,1,2,3,5,15,4,10,6,7,0,9,13],
         [11,10,5,14,6,13,9,0,12,8,15,3,2,4,7,1], [13,7,15,4,1,2,6,14,9,11,3,0,8,5,12,10]],
        [[2,8,11,13,15,7,6,14,3,1,9,4,0,10,12,5], [1,14,2,11,4,12,3,7,6,13,10,5,15,9,0,8],
         [4,12,7,5,1,6,9,10,0,14,13,8,2,11,3,15], [11,9,5,1,12,3,13,14,6,4,7,15,2,0,8,10]]
    ]
    private static let rs: [[UInt8]] = [
        [1,0xa4,0x55,0x87,0x5a,0x58,0xdb,0x9e], [0xa4,0x56,0x82,0xf3,0x1e,0xc6,0x68,0xe5],
        [2,0xa1,0xfc,0xc1,0x47,0xae,0x3d,0x19], [0xa4,0x55,0x87,0x5a,0x58,0xdb,0x9e,3]
    ]
    private static func gf(_ aa: UInt8, _ bb: UInt8, _ poly: UInt8) -> UInt8 {
        var a = aa, b = bb, result: UInt8 = 0
        while a > 0 { if a & 1 != 0 { result ^= b }; a >>= 1; b = (b << 1) ^ (b & 0x80 != 0 ? poly : 0) }
        return result
    }
    private static func box(_ i: Int, _ x: UInt8) -> UInt8 {
        let a = x >> 4, b = x & 15
        let c = q[i][0][Int(a ^ b)], d = q[i][1][Int((a ^ ((b << 3) | (b >> 1)) ^ (a << 3)) & 15)]
        return (q[i][3][Int((c ^ ((d << 3) | (d >> 1)) ^ (c << 3)) & 15)] << 4) | q[i][2][Int(c ^ d)]
    }
    private static func mds(_ x: UInt8, _ column: Int) -> UInt32 {
        let a = gf(x, 0x5b, 0x69), b = gf(x, 0xef, 0x69)
        return [[x,a,b,b], [b,b,a,x], [a,b,x,b], [a,x,b,a]][column].le32(0)
    }
    private static func h(_ x: UInt32, _ key: [UInt8], _ offset: Int) -> UInt32 {
        var y = x.leBytes
        for i in 0..<4 { y[i] = box([1,0,0,1][i], y[i]) ^ key[24 + offset * 4 + i] }
        for i in 0..<4 { y[i] = box([1,1,0,0][i], y[i]) ^ key[16 + offset * 4 + i] }
        let a = 8 + offset * 4, b = offset * 4
        y[0] = box(1, box(0, box(0, y[0]) ^ key[a]) ^ key[b])
        y[1] = box(0, box(0, box(1, y[1]) ^ key[a+1]) ^ key[b+1])
        y[2] = box(1, box(1, box(0, y[2]) ^ key[a+2]) ^ key[b+2])
        y[3] = box(0, box(1, box(1, y[3]) ^ key[a+3]) ^ key[b+3])
        return (0..<4).reduce(0) { $0 ^ mds(y[$1], $1) }
    }
    init(key: [UInt8]) {
        precondition(key.count == 32)
        var k = [UInt32](repeating: 0, count: 40), s = [UInt8](repeating: 0, count: 16)
        for x in 0..<20 {
            let a = Self.h(0x01010101 * UInt32(2*x), key, 0)
            let b = Self.h(0x01010101 * UInt32(2*x+1), key, 1).rol(8)
            k[2*x] = a &+ b; k[2*x+1] = (a &+ b &+ b).rol(9)
        }
        for i in 0..<4 { for j in 0..<4 { for n in 0..<8 { s[4*i+j] ^= Self.gf(key[8*i+n], Self.rs[j][n], 0x4d) } } }
        keys = k
        tables = (0..<4).map { column in
            (0..<256).map { value in
                var g = Self.box(Self.order[column][0], UInt8(value))
                for z in 1..<5 { g = Self.box(Self.order[column][z], g ^ s[4*(z-1)+column]) }
                return Self.mds(g, column)
            }
        }
    }
    private func g(_ x: UInt32) -> UInt32 {
        (0..<4).reduce(0) { $0 ^ tables[$1][Int(UInt8(truncatingIfNeeded: x >> (8 * $1)))] }
    }
    func encrypt(_ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count == 16)
        var p = (0..<4).map { bytes.le32($0*4) ^ keys[$0] }
        for r in 0..<8 {
            let k = 4*r+8
            let t1 = g(p[1].rol(8)), t0 = g(p[0]) &+ t1
            p[2] = (p[2] ^ (t0 &+ keys[k])).ror(1)
            p[3] = p[3].rol(1) ^ (t1 &+ t0 &+ keys[k+1])
            let u1 = g(p[3].rol(8)), u0 = g(p[2]) &+ u1
            p[0] = (p[0] ^ (u0 &+ keys[k+2])).ror(1)
            p[1] = p[1].rol(1) ^ (u1 &+ u0 &+ keys[k+3])
        }
        return [p[2]^keys[4], p[3]^keys[5], p[0]^keys[6], p[1]^keys[7]].flatMap(\.leBytes)
    }
    func decrypt(_ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count == 16)
        var c = [bytes.le32(8)^keys[6], bytes.le32(12)^keys[7], bytes.le32(0)^keys[4], bytes.le32(4)^keys[5]]
        for r in (0..<8).reversed() {
            let k = 4*r+8
            let t1 = g(c[3].rol(8)), t0 = g(c[2]) &+ t1
            c[0] = c[0].rol(1) ^ (t0 &+ keys[k+2])
            c[1] = (c[1] ^ (t1 &+ t0 &+ keys[k+3])).ror(1)
            let u1 = g(c[1].rol(8)), u0 = g(c[0]) &+ u1
            c[2] = c[2].rol(1) ^ (u0 &+ keys[k])
            c[3] = (c[3] ^ (u1 &+ u0 &+ keys[k+1])).ror(1)
        }
        return (0..<4).flatMap { (c[$0]^keys[$0]).leBytes }
    }
}
