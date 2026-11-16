/// A count with its noun, singular for one: "1 song", "2 songs", "0 songs".
nonisolated enum CountText {
    /// `count` and `noun`, with an "s" on the noun unless the count is one.
    static func of(_ count: Int, _ noun: String) -> String {
        "\(count) \(count == 1 ? noun : noun + "s")"
    }

    /// "No songs", "1 song", "N songs".
    static func songs(_ count: Int) -> String {
        switch count {
        case 0: "No songs"
        case 1: "1 song"
        default: "\(count) songs"
        }
    }
}
