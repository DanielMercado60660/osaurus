import Foundation
import Testing
@testable import OsaurusCore

@Suite("Companion presentation")
struct AvatarPresentationTests {
    @Test func reactionExpiryAndPriority() {
        var scheduler = AvatarReactionScheduler()
        scheduler.trigger(.oops, at: 10)
        scheduler.trigger(.happy, at: 10.2)
        #expect(scheduler.visible(over: .idle, at: 10.3) == .oops)
        scheduler.trigger(.surprised, at: 10.4)
        #expect(scheduler.visible(over: .listening(1), at: 10.5) == .surprised)
        #expect(scheduler.visible(over: .speaking(1), at: 10.5) == .surprised)
        scheduler.expire(at: 11.4)
        #expect(scheduler.reaction == nil)
        scheduler.trigger(.happy, at: 12)
        #expect(scheduler.visible(over: .listening(0), at: 12.1) == .happy)
        #expect(scheduler.visible(over: .thinking, at: 12.1) == nil)
        #expect(scheduler.visible(over: .speaking(1), at: 12.1) == nil)
        #expect(scheduler.visible(over: .error, at: 12.1) == nil)
        #expect(scheduler.visible(over: .idle, at: 14) == nil)
    }

    @Test(arguments: [0.0, 0.25, 0.5, 1.0])
    func idleDelayBounds(unit: Double) throws {
        var scheduler = AvatarIdleScheduler()
        scheduler.update(idle: true, at: 100, random: { unit })
        let next = try #require(scheduler.nextAt)
        #expect(next == 120 + unit * 40)
        #expect((120...160).contains(next))
        scheduler.update(idle: true, at: next - 0.01, random: { unit })
        #expect(scheduler.action == nil)
        scheduler.update(idle: true, at: next, random: { unit })
        #expect(scheduler.action != nil)
        scheduler.update(idle: true, at: next + 2.4, random: { unit })
        #expect(scheduler.action == nil)
        #expect(try #require(scheduler.nextAt) >= next + 20)
    }

    @Test(arguments: [AvatarMood.listening(1), .speaking(1), .thinking, .error])
    func activityCancelsIdleAction(mood: AvatarMood) {
        var scheduler = AvatarIdleScheduler()
        scheduler.update(idle: true, at: 0, random: { 0 })
        scheduler.update(idle: true, at: 20, random: { 0.5 })
        #expect(scheduler.action == .stretch)
        scheduler.update(idle: mood == .idle, at: 21, random: { 0 })
        #expect(scheduler.action == nil)
        #expect(scheduler.nextAt == nil)
        scheduler.update(idle: true, at: 100, random: { 1 })
        #expect(scheduler.nextAt == 160)
        #expect(scheduler.action == nil)
    }

    @Test func captionsAdvanceOnlyOnPlaybackAndExpire() {
        var captions = AvatarCaptionState()
        captions.begin(epoch: 7)
        captions.append("First sentence. Second sentence.", epoch: 7)
        #expect(captions.visible(at: 0).isEmpty)
        captions.playback("First sentence.", epoch: 7)
        #expect(captions.visible(at: 1) == "First sentence.")
        captions.append(" A third sentence.", epoch: 7)
        #expect(captions.visible(at: 2) == "First sentence.")
        captions.playback("Second sentence.", epoch: 7)
        #expect(captions.visible(at: 3) == "Second sentence.")
        captions.finish(epoch: 7, at: 4)
        captions.playback("Late callback.", epoch: 7)
        #expect(captions.visible(at: 5.9) == "Second sentence.")
        #expect(captions.visible(at: 6).isEmpty)
    }

    @Test func captionsRejectOldTurnsAndClearOnInterruption() {
        var captions = AvatarCaptionState()
        captions.begin(epoch: 1)
        captions.playback("Old.", epoch: 1)
        captions.clear()
        captions.playback("Discarded audio.", epoch: 1)
        #expect(captions.visible(at: 0).isEmpty)
        captions.begin(epoch: 2)
        captions.append("New.", epoch: 2)
        captions.playback("New.", epoch: 2)
        captions.append("Stale.", epoch: 1)
        captions.playback("Stale.", epoch: 1)
        captions.finish(epoch: 1, at: 0)
        #expect(captions.streamedText == "New.")
        #expect(captions.visible(at: 100) == "New.")
    }

    @Test func accessoryMappingAndFrameBudgets() {
        #expect(AvatarAccessory.mascot("green") == .leaf)
        #expect(AvatarAccessory.mascot("purple") == .glasses)
        #expect(AvatarAccessory.mascot("red") == .scarf)
        #expect(AvatarAccessory.mascot(nil) == .none)
        for mood: AvatarMood in [.idle, .listening(1), .thinking, .error] {
            #expect(mood.frameInterval >= 0.1)
        }
        #expect(AvatarMood.speaking(1).frameInterval == 1.0 / 30)
    }
}
