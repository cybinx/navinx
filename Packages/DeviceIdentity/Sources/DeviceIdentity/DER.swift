import Foundation

/// Just enough DER (X.690) to write a certificate request and read a few fields back.
enum DER {
    static func element(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        out.append(length(content.count))
        out.append(content)
        return out
    }

    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var rest = count
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func sequence(_ parts: Data...) -> Data { element(0x30, parts.reduce(Data(), +)) }
    static func set(_ parts: Data...) -> Data { element(0x31, parts.reduce(Data(), +)) }
    static func integer(_ value: UInt8) -> Data { element(0x02, Data([value])) }
    static func utf8String(_ text: String) -> Data { element(0x0C, Data(text.utf8)) }
    /// A bit string with no unused bits.
    static func bitString(_ bytes: Data) -> Data { element(0x03, Data([0]) + bytes) }

    /// An object identifier from its dotted form.
    static func oid(_ dotted: String) -> Data {
        let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
        precondition(arcs.count >= 2)
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var rest = arc >> 7
            while rest > 0 {
                chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
                rest >>= 7
            }
            body.append(contentsOf: chunk)
        }
        return element(0x06, body)
    }

    /// One element read from `data` at `offset`: its tag, its content's range, and where the next starts.
    struct Read {
        let tag: UInt8
        let content: Range<Int>
        let end: Int
    }

    static func read(_ data: Data, at offset: Int) -> Read? {
        let bytes = [UInt8](data)
        guard offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        var index = offset + 1
        var count = Int(bytes[index])
        index += 1
        if count & 0x80 != 0 {
            let size = count & 0x7F
            guard size > 0, size <= 4, index + size <= bytes.count else { return nil }
            count = 0
            for byte in bytes[index..<index + size] { count = count << 8 | Int(byte) }
            index += size
        }
        guard index + count <= bytes.count else { return nil }
        return Read(tag: tag, content: index..<index + count, end: index + count)
    }
}
