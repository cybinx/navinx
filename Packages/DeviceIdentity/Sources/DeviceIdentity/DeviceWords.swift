import CryptoKit
import Foundation

/// The four words a device shows on its waiting screen, worked out from its public key exactly as the
/// add-on does: `SHA256("navinx-words-v1\n" + SubjectPublicKeyInfo)`, its first four bytes, each an index
/// into the same list of 256 words (`words.txt`, a copy of the add-on's `Server/panel/words.txt`).
public enum DeviceWords {
    public static let list: [String] = {
        guard let url = Bundle.module.url(forResource: "words", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }()

    public static func indexes(subjectPublicKeyInfo: Data) -> [Int] {
        var data = Data("navinx-words-v1\n".utf8)
        data.append(subjectPublicKeyInfo)
        return SHA256.hash(data: data).prefix(4).map(Int.init)
    }

    /// The four words, or none if the list didn't load (it always ships with the app).
    public static func words(subjectPublicKeyInfo: Data) -> [String] {
        let list = list
        guard list.count == 256 else { return [] }
        return indexes(subjectPublicKeyInfo: subjectPublicKeyInfo).map { list[$0] }
    }
}
