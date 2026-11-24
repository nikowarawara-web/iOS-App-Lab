let sentence = "「未来へ」、送ります。"
var testDraft = LetterDraft()
testDraft.edit("「未来へ」送ります。", isComposing: false)
precondition(!testDraft.canSend(sentence), "A skipped comma must prevent sending")
testDraft.edit("「未来へ」、送ります", isComposing: false)
precondition(!testDraft.canSend(sentence), "A skipped sentence-ending punctuation mark must prevent sending")
testDraft.edit("「未来へ」、送ります。", isComposing: true)
precondition(!testDraft.canSend(sentence), "Uncommitted conversion must prevent sending")
testDraft.edit("  「未来へ」、\n送ります。", isComposing: false)
precondition(testDraft.canSend(sentence), "Whitespace must not prevent sending after a full match")

let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fixture = try JSONDecoder().decode(SceneLibrary.self, from: Data(contentsOf: fixtureURL))
precondition(fixture.entries.count == 29)
let date = Date(timeIntervalSince1970: 1_796_342_400)
for passage in fixture.entries {
    let versions = fixture.priorTexts?[String(passage.image)] ?? []
    precondition(!versions.isEmpty)
    for old in versions {
        let card = Postcard(day: "2026-11-25", date: date, text: old, art: passage.image,
                            description: "以前の説明", title: "以前の題")
        let revised = fixture.revisedPostcard(card)
        precondition(revised.text == passage.text && revised.title == passage.title)
        precondition(revised.art == card.art && revised.day == card.day && revised.date == date)
        precondition(fixture.revisedPostcard(revised).id == revised.id, "Migration must be idempotent")
    }
}
let custom = Postcard(day: "2026-11-25", date: date, text: "自分で書いた文章。", art: 25,
                      description: "自分の絵", title: nil)
precondition(fixture.revisedPostcard(custom).id == custom.id)
print("Typing and postcard migration checks passed")
