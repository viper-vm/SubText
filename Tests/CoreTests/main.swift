// Checks for the app's core logic, compiled for macOS by scripts/test-core.sh.
// The LRCLIB check needs an internet connection.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "PASS" : "FAIL", name, ok ? "" : detail)
    if !ok { failures += 1 }
}

// 1. LRC parsing (made-up lines)
let lrc = "[ar:Someone]\n[00:01.00]Hello there\n[00:05.50][00:20.00]Chorus line\n[00:10.00]\n[00:12.3]Third line\n"
let lines = LRCParser.parse(synced: lrc)
check("lrc count", lines.count == 5, "\(lines.map { ($0.time ?? -1, $0.text) })")
check("lrc order", lines.map { $0.time ?? -1 } == [1.0, 5.5, 10.0, 12.3, 20.0], "\(lines.map { $0.time ?? -1 })")
check("lrc break", lines[2].isBreak)
check("lrc ids", lines.map(\.id) == [0, 1, 2, 3, 4])
check("looksTimed", LRCParser.looksTimed(lrc) && !LRCParser.looksTimed("just words\nmore words"))
let plain = LRCParser.parse(plain: "\n\nOne\nTwo\n\n\n\nThree\n\n")
check("plain collapse", plain.map(\.text) == ["One", "Two", "", "Three"], "\(plain.map(\.text))")

// 2. Title cleaning
let titles: [(String, String)] = [
    ("Kesariya (From \"Brahmastra\")", "Kesariya"),
    ("Love Story - Remastered 2011", "Love Story"),
    ("Song Name (feat. Somebody)", "Song Name"),
    ("Live Forever", "Live Forever"),
    ("Mixed Feelings", "Mixed Feelings"),
    ("Tum Hi Ho - From \"Aashiqui 2\"", "Tum Hi Ho"),
    ("Bella Ciao [Live]", "Bella Ciao"),
    ("(I Can't Get No) Satisfaction", "(I Can't Get No) Satisfaction"),
]
for (input, expected) in titles {
    check("clean \(input)", TitleCleaner.clean(input) == expected, "got \(TitleCleaner.clean(input))")
}
check("primary artist", Track.primaryArtist(from: "Pritam, Arijit Singh") == "Pritam" && Track.primaryArtist(from: "A feat. B") == "A" && Track.primaryArtist(from: "Solo") == "Solo")
check("song key shared", SongKey.make(title: "Kesariya (From \"Brahmastra\")", artist: "Pritam") == SongKey.make(title: "Kesariya", artist: "PRITAM"))

// 3. Claude reply parsing
func g(_ e: ClaudeTranslator.Event?) -> LineGloss? { if case .gloss(_, let x)? = e { return x }; return nil }
check("parse LANG", ClaudeTranslator.parse("LANG\tKorean\tko") == .language(name: "Korean", code: "ko"))
let r1 = ClaudeTranslator.parse("L\t3\tI miss you\tbogo sipeo\t")
check("parse L roman", g(r1)?.translation == "I miss you" && g(r1)?.romanization == "bogo sipeo" && g(r1)?.note == nil, "\(String(describing: r1))")
let r2 = ClaudeTranslator.parse("L\t4\tHello\t\tA greeting used at night")
check("parse L note", g(r2)?.romanization == nil && g(r2)?.note == "A greeting used at night", "\(String(describing: r2))")
check("parse id", { if case .gloss(let id, _)? = r2 { return id == 4 }; return false }())
check("parse <TAB>", g(ClaudeTranslator.parse("L<TAB>5<TAB>Hi<TAB><TAB>"))?.translation == "Hi")
check("parse pipes", g(ClaudeTranslator.parse("L | 6 | Bye | | "))?.translation == "Bye")
check("parse ABOUT", ClaudeTranslator.parse("ABOUT\tA song about leaving home.") == .about("A song about leaving home."))
check("parse junk", ClaudeTranslator.parse("Here is your translation:") == nil && ClaudeTranslator.parse("") == nil)
let prompt = ClaudeTranslator.userPrompt(track: Track(title: "T", artist: "A", primaryArtist: "A"), lines: [LyricLine(id: 7, time: 1, text: "x")], target: "English")
check("user prompt numbering", prompt.contains("7\tx\n"))

// 4. Romanization and detection (short greetings, not lyrics)
let samples: [(String, String?, String)] = [
    ("안녕하세요", "ko", "annyeonghaseyo"),
    ("नमस्ते दुनिया", "hi", "namaste duniya"),
    ("你好", "zh-Hans", "nǐ hǎo"),
    ("Привет мир", "ru", "privet mir"),
]
for (text, code, expected) in samples {
    let r = LanguageTools.romanize(text, languageCode: code)
    check("roman \(code ?? "")", r?.lowercased() == expected, "got \(r ?? "nil")")
}
let ja = LanguageTools.romanize("今日は良い天気です", languageCode: "ja")
print("INFO ja romaji:", ja ?? "nil")
check("roman latin nil", LanguageTools.romanize("hello world", languageCode: "en") == nil)
let ko = LanguageTools.detect([LyricLine(id: 0, text: "오늘은 날씨가 정말 좋네요"), LyricLine(id: 1, text: "우리 같이 산책하러 갈까요")])
check("detect ko", ko?.code == "ko", "\(String(describing: ko))")
let es = LanguageTools.detect([LyricLine(id: 0, text: "Hoy hace un día muy bonito"), LyricLine(id: 1, text: "Vamos a caminar por la playa")])
check("detect es", es?.code == "es", "\(String(describing: es))")
let apple = await LanguageTools.appleSupports("ko", target: "en")
let applePa = await LanguageTools.appleSupports("pa", target: "en")
print("INFO apple ko->en:", apple, " pa->en:", applePa)

// 5. Live LRCLIB lookup for a public-domain song (prints counts only)
let bella = Track(title: "Bella Ciao", artist: "Bella Ciao", primaryArtist: "Bella Ciao", album: nil, duration: 127)
let found = try await LyricsService.lyrics(for: bella)
check("lrclib lookup", found != nil && (found?.lines.count ?? 0) > 5, "lines \(found?.lines.count ?? 0)")
print("INFO lrclib: \(found?.lines.count ?? 0) lines, synced \(found?.synced ?? false)")

// 6. Romanized Hindi/Punjabi must not be treated as Indonesian (made-up phrases)
func lines(_ t: String) -> [LyricLine] { t.split(separator: "\n").enumerated().map { LyricLine(id: $0.offset, text: String($0.element)) } }
let hiLatn = LanguageTools.detect(lines("tum kahan ho mere dil ki baat suno\nmain tere bina adhoora hoon\nchal saath chalein"))
check("romanized hindi", hiLatn?.code == "hi-Latn" && hiLatn?.appleCanTranslate == false, "\(String(describing: hiLatn))")
let paLatn = LanguageTools.detect(lines("ve main tainu yaad karda haan\nsohneya tu kithe gaya\nmenu dass de"))
check("romanized punjabi", paLatn?.code == "hi-Latn", "\(String(describing: paLatn))")
let esOK = LanguageTools.detect(lines("Hoy hace un día muy bonito\nvamos a caminar por la playa\nde la mano con mi amor"))
check("spanish untouched", esOK?.code == "es" && esOK?.appleCanTranslate == true, "\(String(describing: esOK))")
let itOK = LanguageTools.detect(lines("Io ho visto il mare e la luna\nmio caro amico non piangere\nche domani si torna a casa"))
check("italian untouched", itOK?.code == "it", "\(String(describing: itOK))")
let enOK = LanguageTools.detect(lines("I walked along the river\nthinking of the summer days\nwhen the main road was empty"))
check("english untouched", enOK?.code == "en", "\(String(describing: enOK))")


// 7. Asking about a line (made-up lines)
let qaLines = (0..<10).map { LyricLine(id: $0, time: Double($0), text: "line number \($0)") }
let qaLyrics = Lyrics(lines: qaLines, synced: true)
let qaTrack = Track(title: "Test Song", artist: "Test Artist", primaryArtist: "Test Artist")
let first = LinePrompt.firstMessage(track: qaTrack, lyrics: qaLyrics, line: qaLines[5], translation: "a translation",
                                    about: "A test song.", question: "What does it mean?")
check("ask: marks the line", first.contains("» line number 5\n"), first)
check("ask: three lines each side", first.contains("  line number 2\n") && first.contains("  line number 8\n")
      && !first.contains("line number 1\n") && !first.contains("line number 9\n"), first)
check("ask: carries translation, summary and question", first.contains("a translation") && first.contains("A test song.")
      && first.hasSuffix("My question: What does it mean?"))
let edge = LinePrompt.firstMessage(track: qaTrack, lyrics: qaLyrics, line: qaLines[0], translation: nil, about: nil, question: "Q")
check("ask: window clamps at the start", edge.contains("» line number 0\n") && edge.contains("  line number 3\n"), edge)
let history = [LineQuestion(question: "Q1", answer: "A1"), LineQuestion(question: "Q2", answer: "A2")]
let turns = LinePrompt.turns(history: history, newQuestion: "Q3") { "CONTEXT+" + $0 }
check("ask: follow-up turns", turns.map(\.role) == [.user, .assistant, .user, .assistant, .user]
      && turns.map(\.text) == ["CONTEXT+Q1", "A1", "Q2", "A2", "Q3"], "\(turns)")
check("ask: first question", LinePrompt.turns(history: [], newQuestion: "Q") { "C+" + $0 }.map(\.text) == ["C+Q"])

// 8. Request shape per model
func body(_ r: URLRequest) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:] }
let opus = try ClaudeAPI.request(apiKey: "k", model: .opus, system: "s", turns: turns, maxTokens: 4000)
let ob = body(opus)
check("request: opus shape", ob["model"] as? String == "claude-opus-5-5" && ob["stream"] as? Bool == true
      && ob["fallbacks"] as? String == "default" && (ob["output_config"] as? [String: String])?["effort"] == "low"
      && opus.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01"
      && opus.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01"
      && (ob["messages"] as? [[String: String]])?.count == 5, "\(ob)")
let haiku = body(try ClaudeAPI.request(apiKey: "k", model: .haiku, system: "s", turns: turns, maxTokens: 4000))
check("request: haiku has no effort or fallbacks", haiku["fallbacks"] == nil && haiku["output_config"] == nil
      && haiku["model"] as? String == "claude-haiku-4-5")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
