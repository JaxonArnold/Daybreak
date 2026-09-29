import Foundation

/// One round of the memory mission: tiles light up in `sequence`, and the
/// user taps them back in order.
struct MemoryRound {
    static let tileCount = 9

    /// Round 1 shows 3 tiles; each round adds one.
    static func length(forRound round: Int) -> Int { round + 2 }

    enum TapResult { case correct, wrong, complete }

    let sequence: [Int]
    private(set) var progress = 0

    init(sequence: [Int]) {
        self.sequence = sequence
    }

    /// A wrong tap starts the round over.
    mutating func tap(_ tile: Int) -> TapResult {
        guard tile == sequence[progress] else {
            progress = 0
            return .wrong
        }
        progress += 1
        if progress == sequence.count {
            progress = 0
            return .complete
        }
        return .correct
    }

    /// Random tiles, never the same one twice in a row — a repeat would look
    /// like one long flash.
    static func random(length: Int) -> MemoryRound {
        var sequence: [Int] = []
        while sequence.count < length {
            let tile = Int.random(in: 0..<tileCount)
            if tile != sequence.last { sequence.append(tile) }
        }
        return MemoryRound(sequence: sequence)
    }
}

/// The typing mission: retype short wake-up phrases.
enum TypingMission {
    /// No hyphens: "wake-up" vs "wake up" would be a cruel mismatch.
    static let phrases = [
        "I am awake and ready for the day",
        "Today is going to be a good day",
        "My feet are on the floor",
        "I will not go back to sleep",
        "Every morning is a fresh start",
        "Rise and shine, it is a new day",
        "Open the curtains and let the light in",
        "Small steps every day add up",
        "Coffee first, then conquer the world",
        "One more minute never helps",
        "The early bird catches the worm",
        "No more snoozing for me today",
        "I choose to start today strong",
        "Up and at them",
        "Good morning to me",
    ]

    static func randomPhrases(_ count: Int) -> [String] {
        Array(phrases.shuffled().prefix(count))
    }

    /// Case, punctuation, and extra spaces don't matter; the words do.
    static func matches(_ input: String, _ phrase: String) -> Bool {
        normalize(input) == normalize(phrase)
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
