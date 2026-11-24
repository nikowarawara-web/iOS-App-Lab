import Foundation

struct Passage: Equatable, Decodable {
    let title: String?
    let text: String
    let image: Int
    let description: String

    static func letters(_ text: String) -> [Character] {
        text.folding(options: .widthInsensitive, locale: Locale(identifier: "ja_JP"))
            .precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

struct SceneLibrary: Decodable {
    let entries: [Passage]
    let legacyDescriptions: [String]

    static func load() -> Self {
        if let url = Bundle.main.url(forResource: "scenes", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let library = try? JSONDecoder().decode(Self.self, from: data),
           !library.entries.isEmpty, library.legacyDescriptions.count == 8 {
            return library
        }
        let artwork = "朝の光が差す窓辺"
        return Self(entries: [Passage(title: nil, text: "朝の光が、机の上のノートを照らしています。", image: 7, description: artwork)],
                    legacyDescriptions: Array(repeating: artwork, count: 8))
    }

    func revisedPostcard(_ card: Postcard) -> Postcard {
        let previousDeliveryText = "歩く人が立ち止まると、荷物を運ぶロボットも少し手前で待ちます。その距離なら、体をひねらず袋を取れると教えてもらいます。"
        guard card.art == 25, card.text == previousDeliveryText,
              let revised = entries.first(where: { $0.image == card.art }) else { return card }
        return Postcard(day: card.day, date: card.date, text: revised.text, art: card.art,
                        description: revised.description, title: revised.title)
    }

    func passage(on date: Date, custom: String?) -> Passage {
        if let custom, !Passage.letters(custom).isEmpty {
            if let passage = entries.first(where: { $0.text == custom }) { return passage }
            let clues = [(0, "コード|判断|プログラム"), (1, "段差|救助|災害"), (2, "試作|仲間"),
                         (3, "化学島|分子"), (4, "歯車|木製|木の部品"), (6, "介護|支援|荷物")]
            let index = clues.first { custom.range(of: $0.1, options: .regularExpression) != nil }?.0 ?? 7
            return Passage(title: nil, text: custom, image: index, description: legacyDescriptions[index])
        }
        let digits = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let civilDay = utc.date(from: digits) ?? date
        let day = Int(floor(civilDay.timeIntervalSince1970 / 86_400))
        return entries[(day % entries.count + entries.count) % entries.count]
    }
}

struct Postcard: Codable, Identifiable {
    let day: String
    let date: Date
    let text: String
    let art: Int
    let description: String
    let title: String?
    var id: String { day + ":" + text }

    static func dayKey(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

struct MatchState {
    let matched: Int
    let count: Int
    let excess: Bool
    let incorrect: Bool
    var complete: Bool { count > 0 && matched == count && !excess && !incorrect }

    init(reference: String, typed: String) {
        let target = Passage.letters(reference)
        let input = Passage.letters(typed)
        matched = zip(target, input).prefix { $0.0 == $0.1 }.count
        count = target.count
        excess = input.count > target.count
        incorrect = matched < min(target.count, input.count)
    }
}
