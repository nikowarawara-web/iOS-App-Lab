import Foundation

struct Passage: Equatable {
    let text: String
    let image: Int
    let description: String

    static func letters(_ text: String) -> [Character] {
        text.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

struct SceneLibrary: Decodable {
    let passages: [String]
    let artDescriptions: [String]

    static func load() -> Self {
        guard let url = Bundle.main.url(forResource: "scenes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(Self.self, from: data),
              !library.passages.isEmpty, library.artDescriptions.count == 8 else {
            return Self(passages: ["朝の光が、机の上のノートを照らしています。"], artDescriptions: Array(repeating: "朝の風景", count: 8))
        }
        return library
    }

    func passage(on date: Date, custom: String?) -> Passage {
        if let custom, !Passage.letters(custom).isEmpty {
            if let index = passages.firstIndex(of: custom) {
                return make(custom, image: index / 2)
            }
            let clues = ["コード|判断|プログラム", "段差|救助|災害", "試作|仲間", "化学島|分子", "歯車|木製|木の部品", "鴨川|川沿い|川辺", "介護|支援|荷物"]
            let index = clues.firstIndex { custom.range(of: $0, options: .regularExpression) != nil } ?? 7
            return make(custom, image: index)
        }
        let digits = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let civilDay = utc.date(from: digits) ?? date
        let day = Int(floor(civilDay.timeIntervalSince1970 / 86_400))
        let index = (day % passages.count + passages.count) % passages.count
        return make(passages[index], image: index / 2)
    }

    private func make(_ text: String, image: Int) -> Passage {
        Passage(text: text, image: image, description: artDescriptions[image])
    }
}

struct Postcard: Codable, Identifiable {
    let day: String
    let date: Date
    let text: String
    let art: Int
    let description: String
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
