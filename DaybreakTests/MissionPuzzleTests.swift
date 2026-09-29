import Foundation
import Testing
import UIKit
@testable import Daybreak

struct MissionPuzzleTests {

    // MARK: - Memory

    @Test func repeatingThePatternCompletesTheRound() {
        var round = MemoryRound(sequence: [0, 4, 8])
        #expect(round.tap(0) == .correct)
        #expect(round.tap(4) == .correct)
        #expect(round.tap(8) == .complete)
    }

    @Test func aWrongTapStartsTheRoundOver() {
        var round = MemoryRound(sequence: [0, 4, 8])
        #expect(round.tap(0) == .correct)
        #expect(round.tap(5) == .wrong)
        // Back to the first tile — the earlier correct tap doesn't carry over.
        #expect(round.tap(4) == .wrong)
        #expect(round.tap(0) == .correct)
    }

    @Test func randomPatternsNeverRepeatATileBackToBack() {
        for length in 3...8 {
            let round = MemoryRound.random(length: length)
            #expect(round.sequence.count == length)
            #expect(round.sequence.allSatisfy { (0..<MemoryRound.tileCount).contains($0) })
            #expect(zip(round.sequence, round.sequence.dropFirst()).allSatisfy { $0 != $1 })
        }
    }

    @Test func patternsGrowEachRound() {
        #expect(MemoryRound.length(forRound: 1) == 3)
        #expect(MemoryRound.length(forRound: 4) == 6)
    }

    // MARK: - Typing

    @Test func typingIgnoresCapitalsPunctuationAndSpacing() {
        let phrase = "Rise and shine, it is a new day"
        #expect(TypingMission.matches("rise and shine it is a new day", phrase))
        #expect(TypingMission.matches("  RISE AND SHINE,  it is a new day. ", phrase))
    }

    @Test func typingNeedsEveryWord() {
        let phrase = "My feet are on the floor"
        #expect(!TypingMission.matches("My feet are on the", phrase))
        #expect(!TypingMission.matches("My feet are on the flor", phrase))
    }

    @Test func randomPhrasesAreDistinct() {
        let phrases = TypingMission.randomPhrases(5)
        #expect(phrases.count == 5)
        #expect(Set(phrases).count == 5)
    }

    // MARK: - Photo

    func drawn(_ draw: (CGContext) -> Void) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { draw($0.cgContext) }
    }

    static let inSimulator: Bool = {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }()

    @Test(.disabled(if: inSimulator, "Vision feature prints only run on a real device"))
    func photoMatcherRecognizesTheSameSpot() async throws {
        let spot = drawn { ctx in
            UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            UIColor.systemOrange.setFill(); ctx.fillEllipse(in: CGRect(x: 150, y: 250, width: 300, height: 300))
        }
        let elsewhere = drawn { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            UIColor.systemGreen.setFill()
            for y in stride(from: 0, to: 800, by: 80) { ctx.fill(CGRect(x: 0, y: y, width: 600, height: 40)) }
        }
        let reference = try #require(await PhotoMatcher.makeReference(from: spot))
        let same = try #require(await PhotoMatcher.distance(from: spot, to: reference))
        let different = try #require(await PhotoMatcher.distance(from: elsewhere, to: reference))
        #expect(same < PhotoMatcher.matchThreshold)
        #expect(different > same)
    }
}
