import AVFoundation
import Foundation
@testable import StupidSocialCore
import XCTest

@MainActor
final class AdapterChatViewModelTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appending(path: "AdapterChatViewModelTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testConnectLoadsAndShowsTheAdaptersChat() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertEqual(chat.state, .connected)
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2"])
        XCTAssertEqual(chat.title, "Loaded")
        XCTAssertFalse(chat.canReact, "the adapter can't react")
        chat.disconnect()
    }

    func testAFailedLoadDisconnectsWithTheReason() async {
        let adapter = FakeAdapter()
        adapter.error = URLError(.notConnectedToInternet)
        let chat = makeChat(adapter)
        await chat.connect()
        guard case .disconnected = chat.state else { return XCTFail("expected disconnected, got \(chat.state)") }
    }

    func testReactingAdaptersEnableReactions() async {
        let adapter = FakeReactingAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertTrue(chat.canReact)
        await chat.toggleReaction("👍", on: "1")
        XCTAssertEqual(chat.reactions["1"]?.first?.emoji, "👍")
        chat.disconnect()
    }

    func testTheSnapshotRestoresWithItsDividerInTheFirstRender() async {
        let adapter = FakeAdapter()
        adapter.readUpTo = 1
        adapter.pages = [[message(1), message(2), message(3)]]
        let first = makeChat(adapter)
        await first.connect()
        first.disconnect()

        let reopened = FakeAdapter()
        reopened.readUpTo = 1
        let chat = makeChat(reopened)
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2", "3"], "opens with the snapshot")
        XCTAssertEqual(chat.firstUnreadMessageId, "2")
        XCTAssertEqual(chat.unreadCount, 2)
    }

    func testAdapterChangesOutsideCallsReachTheScreen() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        adapter.info.title = "Renamed"
        adapter.onChange?()
        XCTAssertEqual(chat.title, "Renamed")
        chat.disconnect()
    }

    func testSendingShowsAtOnceThenTheNetworksCopy() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Hello"
        await chat.send()
        XCTAssertEqual(adapter.sent.map(\.text), ["Hello"])
        XCTAssertEqual(chat.messages.last?.id, "sent-1")
        XCTAssertFalse(chat.messages.contains(where: \.isSending))
        XCTAssertEqual(chat.draft, "")
        chat.disconnect()
    }

    func testMarkingReadMovesTheCountAtOnceAndSendsOnce() async throws {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1), message(2), message(3)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertEqual(chat.unreadCount, 3)
        chat.markRead(upTo: message(2))
        chat.markRead(upTo: message(3))
        XCTAssertEqual(chat.unreadCount, 0)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(adapter.readMarks, [3])
        chat.disconnect()
    }

    func testLiveAdaptersFollowWhileOpenAndPushedMessagesShow() async {
        let adapter = FakeLiveAdapter()
        adapter.pages = [[message(1)], [message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        await chat.connect()
        XCTAssertEqual(adapter.followCount, 1, "connecting again while open doesn't follow twice")
        adapter.push(message(2))
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2"])
        chat.disconnect()
        XCTAssertFalse(adapter.isFollowing)
        await chat.connect()
        XCTAssertEqual(adapter.followCount, 2, "reconnects after leaving")
        chat.disconnect()
    }

    func testALostConnectionShowsAndReconnectsOnTheNextConnect() async {
        let adapter = FakeLiveAdapter()
        adapter.pages = [[message(1)], [message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        adapter.onConnectionLost?(URLError(.networkConnectionLost))
        guard case .disconnected = chat.state else { return XCTFail("expected disconnected, got \(chat.state)") }
        adapter.onConnectionLost?(nil)
        XCTAssertEqual(chat.state, .connecting, "closed by the app itself: nothing to report")
        await chat.connect()
        XCTAssertEqual(chat.state, .connected)
        chat.disconnect()
    }

    func testCommandsRunWithoutASendingCopy() async {
        let adapter = FakeWindowingAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "/nick ada"
        await chat.send()
        XCTAssertEqual(adapter.commands, ["/nick ada"])
        XCTAssertTrue(adapter.sent.isEmpty)
        XCTAssertEqual(chat.draft, "")
        XCTAssertEqual(chat.messages.map(\.id), ["1"])
        chat.disconnect()
    }

    func testJumpingOutsideTheLoadedMessagesShowsAWindow() async {
        let adapter = FakeWindowingAdapter()
        adapter.pages = [[message(50)]]
        let chat = makeChat(adapter)
        await chat.connect()
        await chat.jump(to: "10")
        XCTAssertEqual(chat.jumpTarget, "10")
        XCTAssertTrue(chat.hasLaterMessages)
        await chat.jump(to: "404")
        XCTAssertEqual(chat.errorMessage, "That message is no longer available.")
        await chat.jumpToLatest()
        XCTAssertFalse(chat.hasLaterMessages)
        XCTAssertEqual(chat.messages.map(\.id), ["50"])
        chat.disconnect()
    }

    func testReferencedMessagesComeFromTheAdapter() async {
        let adapter = FakeLiveAdapter()
        adapter.pages = [[message(1)]]
        adapter.referencedMessages = ["0": message(0)]
        adapter.unavailableReferences = ["-1"]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertEqual(chat.message(withId: "0")?.text, "Message 0")
        XCTAssertTrue(chat.isUnavailableReference("-1"))
        chat.disconnect()
    }

    func testUnseenReactionsShowAndSeeingThemSendsOnce() async throws {
        let adapter = FakeUnseenReactionsAdapter()
        adapter.pages = [[message(1, own: true), message(2, own: true), message(3, own: true)]]
        adapter.unseen = ["1", "3"]
        let chat = makeChat(adapter)
        var rowCounts: [Int?] = []
        chat.summaryDidChange = { _, _, _, count in rowCounts.append(count) }
        await chat.connect()
        XCTAssertEqual(chat.unseenReactionMessageIds, ["1", "3"])
        chat.reactionsSeen(on: ["1", "2"])
        chat.reactionsSeen(on: ["3"])
        XCTAssertEqual(chat.unseenReactionMessageIds, [], "seen at once")
        XCTAssertEqual(rowCounts.last, 0, "the row follows")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(adapter.seenSends, [["1", "3"]], "one send covers both")
        chat.disconnect()
    }

    func testReactionsAreOnlySeenOnceConnected() {
        let adapter = FakeUnseenReactionsAdapter()
        adapter.unseen = ["1"]
        let chat = makeChat(adapter)
        chat.reactionsSeen(on: ["1"])
        XCTAssertEqual(chat.unseenReactionMessageIds, ["1"], "cached messages shown before connecting don't count")
    }

    func testChatsWithoutUnseenReactionsLeaveTheRowsCount() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        var rowCounts: [Int?] = []
        chat.summaryDidChange = { _, _, _, count in rowCounts.append(count) }
        await chat.connect()
        XCTAssertFalse(rowCounts.isEmpty)
        XCTAssertTrue(rowCounts.allSatisfy { $0 == nil })
        chat.disconnect()
    }

    func testReceiptsShowSentThenSeenOnTheUsersConfirmedMessages() async {
        let adapter = FakeReceiptsAdapter()
        adapter.pages = [[message(1, own: true), message(2), message(3, own: true)]]
        adapter.seenUpTo = 1
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertEqual(chat.receipt(for: chat.messages[0]), .seen)
        XCTAssertNil(chat.receipt(for: chat.messages[1]), "others' messages have none")
        XCTAssertEqual(chat.receipt(for: chat.messages[2]), .sent)
        adapter.seenUpTo = 3
        adapter.onChange?()
        XCTAssertEqual(chat.receipt(for: chat.messages[2]), .seen, "follows the adapter")
        chat.disconnect()
    }

    func testChatsWithoutReceiptsShowNone() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(1, own: true)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertNil(chat.receipt(for: chat.messages[0]))
        chat.disconnect()
    }

    func testJumpingToAnUnloadedMessageWithoutWindowsPagesBack() async {
        let adapter = FakeUnseenReactionsAdapter()
        adapter.pages = [[message(3, own: true)]]
        adapter.earlierPages = [[message(2, own: true)], [message(1, own: true)]]
        adapter.unseen = ["1"]
        let chat = makeChat(adapter)
        await chat.connect()
        await chat.jumpToNextUnseenReaction()
        XCTAssertEqual(chat.jumpTarget, "1")
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2", "3"])
        chat.disconnect()
    }

    func testSearchFindsLoadedMessagesAndStepsBetweenThem() async {
        let adapter = FakeAdapter()
        adapter.pages = [[said(1, "Lunch at noon?"), said(2, "sure"), said(3, "Café LUNCH was great")]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.beginSearch()
        chat.updateSearch("lunch ")
        XCTAssertEqual(chat.searchMatchIds, ["1", "3"], "ignores case, accents and surrounding spaces")
        await chat.submitSearch()
        XCTAssertEqual(chat.searchMatchIndex, 1, "starts at the newest match")
        XCTAssertEqual(chat.jumpTarget, "3")
        await chat.showOlderMatch()
        XCTAssertEqual(chat.jumpTarget, "1")
        XCTAssertFalse(chat.canShowOlderMatch)
        XCTAssertTrue(chat.canShowNewerMatch)
        chat.endSearch()
        XCTAssertNil(chat.searchQuery)
        XCTAssertTrue(chat.searchMatchIds.isEmpty)
        chat.disconnect()
    }

    func testSearchPagesBackForOlderMatches() async {
        let adapter = FakeUnseenReactionsAdapter()
        adapter.pages = [[said(4, "lunch?"), said(5, "ok")]]
        adapter.earlierPages = [[said(3, "nothing")], [said(2, "lunch again")], [said(1, "lunch first")]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.beginSearch()
        chat.updateSearch("lunch")
        await chat.submitSearch()
        XCTAssertEqual(chat.jumpTarget, "4")
        XCTAssertTrue(chat.canShowOlderMatch, "earlier history may have more")
        await chat.showOlderMatch()
        XCTAssertEqual(chat.jumpTarget, "2", "loads pages until one brings an older match, and no further")
        XCTAssertEqual(chat.messages.map(\.id), ["2", "3", "4", "5"])
        XCTAssertEqual(chat.searchMatchIds, ["2", "4"])
        XCTAssertEqual(chat.searchMatchIndex, 0)
        chat.disconnect()
    }

    func testSearchWithNothingLoadedLooksFurtherBackOnReturn() async {
        let adapter = FakeUnseenReactionsAdapter()
        adapter.pages = [[said(3, "hi")]]
        adapter.earlierPages = [[said(2, "nope")], [said(1, "the plan")]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.beginSearch()
        chat.updateSearch("plan")
        XCTAssertTrue(chat.searchMatchIds.isEmpty)
        await chat.submitSearch()
        XCTAssertEqual(chat.searchMatchIds, ["1"])
        XCTAssertEqual(chat.jumpTarget, "1")
        chat.disconnect()
    }

    func testSearchMatchesFollowNewMessagesAndKeepTheShownOne() async {
        let adapter = FakeAdapter()
        adapter.pages = [[said(1, "lunch")]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.beginSearch()
        chat.updateSearch("lunch")
        await chat.submitSearch()
        adapter.append(said(2, "more lunch"))
        adapter.onChange?()
        XCTAssertEqual(chat.searchMatchIds, ["1", "2"])
        XCTAssertEqual(chat.searchMatchIndex, 0, "still shows the same message")
        chat.disconnect()
    }

    func testEditingSavesTheTextAndGivesBackWhatWasBeingWritten() async {
        let adapter = FakeEditingAdapter()
        adapter.pages = [[message(1), message(2, own: true)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertFalse(chat.canEdit(message(1)), "someone else's message")
        XCTAssertTrue(chat.canEdit(message(2, own: true)))
        chat.draft = "Half written"
        chat.startReply(to: message(1))
        chat.startEditing(message(2, own: true))
        XCTAssertEqual(chat.draft, "Message 2")
        XCTAssertNil(chat.replyingTo)
        chat.draft = "Changed "
        await chat.send()
        XCTAssertEqual(adapter.edits.map(\.text), ["Changed"])
        XCTAssertEqual(chat.messages.last?.text, "Changed")
        XCTAssertEqual(chat.messages.last?.isEdited, true)
        XCTAssertNil(chat.editingMessage)
        XCTAssertEqual(chat.draft, "Half written")
        XCTAssertEqual(chat.replyingTo?.id, "1")
        chat.disconnect()
    }

    func testStickersAreOfferedOnlyWhereTheAdapterSendsThem() async throws {
        XCTAssertFalse(makeChat(FakeAdapter()).offersStickers)
        let adapter = FakeStickerAdapter()
        let chat = makeChat(adapter)
        XCTAssertTrue(chat.offersStickers)
        let sets = try await chat.stickerSets()
        XCTAssertEqual(sets.map(\.id), ["recent", "set-1"])
        let stickers = try await chat.stickers(inSet: "set-1")
        XCTAssertEqual(stickers.map(\.id), ["7"])
    }

    func testASentStickerShowsAtOnceRepliesAndKeepsTheDraft() async {
        let adapter = FakeStickerAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Half written"
        chat.startReply(to: message(1))
        await chat.send(sticker: adapter.sticker)
        XCTAssertEqual(adapter.sentStickers.map(\.id), ["7"])
        XCTAssertEqual(adapter.sentStickerReplies, ["1"])
        XCTAssertEqual(chat.messages.last?.id, "sticker-1")
        XCTAssertEqual(chat.messages.last?.embeds, [.sticker(adapter.sticker)])
        XCTAssertFalse(chat.messages.contains(where: \.isSending))
        XCTAssertEqual(chat.draft, "Half written", "a sticker leaves the draft")
        XCTAssertNil(chat.replyingTo)
        chat.disconnect()
    }

    func testAFailedStickerGoesAwayWithTheReason() async {
        let adapter = FakeStickerAdapter()
        adapter.pages = [[message(1)]]
        adapter.stickerError = URLError(.notConnectedToInternet)
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Half written"
        await chat.send(sticker: adapter.sticker)
        XCTAssertEqual(chat.messages.map(\.id), ["1"])
        XCTAssertNotNil(chat.errorMessage)
        XCTAssertEqual(chat.draft, "Half written")
        chat.disconnect()
    }

    func testVoiceMessagesAreOfferedOnlyWhereTheAdapterSendsThem() {
        XCTAssertFalse(makeChat(FakeAdapter()).offersVoiceNotes)
        XCTAssertTrue(makeChat(FakeVoiceAdapter()).offersVoiceNotes)
    }

    func testASentVoiceMessagePlaysItsRecordingWhileSendingAndKeepsTheDraft() async {
        let adapter = FakeVoiceAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Half written"
        chat.startReply(to: message(1))
        let note = ChatVoiceNote(fileURL: URL(fileURLWithPath: "/tmp/voice.caf"), duration: 2.5, waveform: [0, 1])
        var whileSending: (embeds: [ChatEmbed]?, preview: URL?)?
        adapter.onSend = {
            let sending = chat.messages.last
            let previewId = sending?.embeds.first.flatMap { embed -> String? in
                if case let .voice(id, _, _) = embed { return id }
                return nil
            }
            whileSending = await (sending?.embeds, chat.audioPreviewURL(for: previewId ?? ""))
        }
        await chat.send(voice: note)
        guard case .voice(_, 2.5, [0, 1])? = whileSending?.embeds?.first else { return XCTFail("\(String(describing: whileSending))") }
        XCTAssertEqual(whileSending?.preview, note.fileURL)
        XCTAssertEqual(adapter.sentVoices, [note])
        XCTAssertEqual(adapter.sentVoiceReplies, ["1"])
        XCTAssertEqual(chat.messages.last?.id, "voice-1")
        XCTAssertFalse(chat.messages.contains(where: \.isSending))
        XCTAssertEqual(chat.draft, "Half written", "a voice message leaves the draft")
        XCTAssertNil(chat.replyingTo)
        chat.disconnect()
    }

    func testVoiceMessagesGoAsAFileWhereTheNetworkTakesFilesButNotVoice() async throws {
        let adapter = FakeAdapter()
        adapter.acceptsAttachments = true
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertTrue(chat.offersVoiceNotes)
        let recording = try makeRecording()
        try await chat.send(voice: ChatVoiceNote(recordingAt: recording))
        XCTAssertNil(chat.errorMessage)
        XCTAssertEqual(adapter.sent.first?.attachment?.mimeType, "audio/mp4")
        XCTAssertEqual(adapter.sent.first?.attachment?.filename, "Voice Message.m4a")
        XCTAssertFalse(adapter.sent.first?.attachment?.data.isEmpty ?? true)
        chat.disconnect()
    }

    func testForwardIsOfferedOnceTheOpeningScreenTakesIt() async {
        let adapter = FakeForwardingAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertFalse(chat.canForward(message(1)))
        var picked: ChatForward?
        chat.forwardHandler = { picked = $0 }
        XCTAssertTrue(chat.canForward(message(1)))
        await chat.startForward(message(1))
        XCTAssertEqual(picked?.reference, "ref-1")
        XCTAssertEqual(picked?.accountId, "test")
        XCTAssertEqual(picked?.originName, "Ada")
        chat.disconnect()
    }

    func testAForwardInTheSameAccountGoesNativelyAfterTheTypedText() async {
        let adapter = FakeForwardingAdapter()
        adapter.pages = [[message(1)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.stage(ChatForward(message: message(1), network: .telegram, accountId: "test", reference: "ref-1", media: []))
        chat.draft = "Look"
        await chat.send()
        XCTAssertEqual(adapter.sent.map(\.text), ["Look"])
        XCTAssertEqual(adapter.forwarded, ["ref-1"])
        XCTAssertNil(chat.forwarding)
        XCTAssertEqual(chat.messages.last?.id, "forward-1")
        XCTAssertFalse(chat.messages.contains(where: \.isSending))
        chat.disconnect()
    }

    func testAForwardFromAnotherNetworkOrAccountSendsACopyNamingItsOrigin() async {
        let adapter = FakeForwardingAdapter()
        adapter.pages = [[]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.stage(ChatForward(message: message(1), network: .discord, accountId: "other", reference: "discord-ref", media: []))
        await chat.send()
        XCTAssertEqual(adapter.forwarded, [])
        XCTAssertEqual(adapter.sent.map(\.text), ["Forwarded from Ada on Discord\n\nMessage 1"])
        chat.stage(ChatForward(message: message(2), network: .telegram, accountId: "other", reference: "ref-2", media: []))
        await chat.send()
        XCTAssertEqual(adapter.sent.last?.text, "Forwarded from Ada\n\nMessage 2")
        chat.stage(ChatForward(message: message(3, own: true), network: .discord, accountId: "other", reference: nil, media: []))
        await chat.send()
        XCTAssertEqual(adapter.sent.last?.text, "Forwarded from Discord\n\nMessage 3", "the user's own message names no one")
        chat.disconnect()
    }

    func testAForwardWithFilesToAChatWithoutFilesFailsAndStays() async {
        let adapter = FakeAdapter()
        adapter.pages = [[]]
        let chat = makeChat(adapter)
        await chat.connect()
        let forward = ChatForward(message: message(1), network: .discord, accountId: "other", reference: nil, media: [.image(url: URL(fileURLWithPath: "/tmp/photo.jpg"))])
        chat.stage(forward)
        await chat.send()
        XCTAssertEqual(adapter.sent.count, 0)
        XCTAssertNotNil(chat.errorMessage)
        XCTAssertEqual(chat.forwarding, forward)
        XCTAssertFalse(chat.messages.contains(where: \.isSending))
        chat.disconnect()
    }

    /// A short tone as PCM in a CAF file, as the composer records.
    private func makeRecording() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "voice.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
        buffer.frameLength = 24000
        for index in 0 ..< 24000 {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48000) * 0.5)
        }
        try file.write(from: buffer)
        return url
    }

    func testCancellingOrKeepingTheTextSavesNothing() async {
        let adapter = FakeEditingAdapter()
        adapter.pages = [[message(2, own: true)]]
        let chat = makeChat(adapter)
        await chat.connect()
        chat.draft = "Half written"
        chat.startEditing(message(2, own: true))
        chat.cancelEditing()
        XCTAssertEqual(chat.draft, "Half written")
        chat.startEditing(message(2, own: true))
        await chat.send()
        XCTAssertTrue(adapter.edits.isEmpty)
        XCTAssertNil(chat.editingMessage)
        XCTAssertEqual(chat.draft, "Half written")
        chat.disconnect()
    }

    func testAFailedEditShowsTheMessageAsItWasAndReturnsTheEdit() async {
        let adapter = FakeEditingAdapter()
        adapter.pages = [[message(2, own: true)]]
        adapter.editError = URLError(.notConnectedToInternet)
        let chat = makeChat(adapter)
        await chat.connect()
        chat.startEditing(message(2, own: true))
        chat.draft = "Changed"
        await chat.send()
        XCTAssertEqual(chat.messages.last?.text, "Message 2")
        XCTAssertEqual(chat.editingMessage?.id, "2")
        XCTAssertEqual(chat.draft, "Changed")
        XCTAssertNotNil(chat.errorMessage)
        chat.disconnect()
    }

    func testASavedEditShowsUntilTheNetworksCopyArrives() async {
        let adapter = FakeEditingAdapter()
        adapter.pages = [[message(2, own: true)]]
        adapter.appliesEdits = false
        let chat = makeChat(adapter)
        await chat.connect()
        chat.startEditing(message(2, own: true))
        chat.draft = "Changed"
        await chat.send()
        XCTAssertEqual(chat.messages.last?.text, "Changed")
        XCTAssertFalse(chat.canEdit(message(2, own: true)), "not while the edit is still showing")
        adapter.replace(with: [ChatMessage(id: "2", sender: ChatUser(id: "you", name: "You", avatarURL: nil), timestamp: nil, text: "Changed, as the network wrote it", isOwn: true, isEdited: true)])
        adapter.onChange?()
        XCTAssertEqual(chat.messages.last?.text, "Changed, as the network wrote it")
        XCTAssertTrue(chat.canEdit(message(2, own: true)))
        chat.disconnect()
    }

    func testChatsWithoutEditingOfferNone() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(2, own: true)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertFalse(chat.canEdit(message(2, own: true)))
        chat.startEditing(message(2, own: true))
        XCTAssertNil(chat.editingMessage)
        chat.disconnect()
    }

    func testDeletingRemovesTheUsersMessage() async {
        let adapter = FakeDeletingAdapter()
        adapter.pages = [[message(1), message(2, own: true)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertFalse(chat.canDelete(message(1)), "someone else's message")
        XCTAssertTrue(chat.canDelete(message(2, own: true)))
        await chat.delete(message(2, own: true))
        XCTAssertEqual(adapter.deleted, ["2"])
        XCTAssertEqual(chat.messages.map(\.id), ["1"])
        chat.disconnect()
    }

    func testAFailedDeleteKeepsTheMessage() async {
        let adapter = FakeDeletingAdapter()
        adapter.pages = [[message(2, own: true)]]
        adapter.deleteError = URLError(.notConnectedToInternet)
        let chat = makeChat(adapter)
        await chat.connect()
        await chat.delete(message(2, own: true))
        XCTAssertEqual(chat.messages.map(\.id), ["2"])
        XCTAssertNotNil(chat.errorMessage)
        chat.disconnect()
    }

    func testChatsWithoutDeletingOfferNone() async {
        let adapter = FakeAdapter()
        adapter.pages = [[message(2, own: true)]]
        let chat = makeChat(adapter)
        await chat.connect()
        XCTAssertFalse(chat.canDelete(message(2, own: true)))
        chat.disconnect()
    }

    private func makeChat(_ adapter: FakeAdapter) -> AdapterChatViewModel<FakeAdapter> {
        let suite = "AdapterChatViewModelTests-\(UUID().uuidString)"
        return AdapterChatViewModel(
            adapter: adapter,
            accountId: "test",
            snapshotCache: ChatSnapshotCache(directory: directory),
            draftStore: ChatDraftStore(defaults: UserDefaults(suiteName: suite)!),
        )
    }
}

private func message(_ id: Int, own: Bool = false) -> ChatMessage {
    ChatMessage(id: "\(id)", sender: ChatUser(id: own ? "you" : "ada", name: own ? "You" : "Ada", avatarURL: nil), timestamp: Date(timeIntervalSince1970: Double(id)), text: "Message \(id)", isOwn: own)
}

private func said(_ id: Int, _ text: String) -> ChatMessage {
    ChatMessage(id: "\(id)", sender: ChatUser(id: "ada", name: "Ada", avatarURL: nil), timestamp: Date(timeIntervalSince1970: Double(id)), text: text, isOwn: false)
}

/// Read position is a message id, like Telegram's.
@MainActor
private class FakeAdapter: ChatAdapter {
    let network = SocialNetwork.telegram
    let key = "fake:1"
    let canReply = true
    var acceptsAttachments = false
    let pollInterval: Duration? = .seconds(60)
    var onChange: (() -> Void)?
    var info = ChatInfo(title: "Fake", subtitle: "Test")
    private(set) var messages: [ChatMessage] = []
    var reactions: [String: [ChatReaction]] = [:]
    var hasEarlierMessages = false

    var pages: [[ChatMessage]] = []
    var error: Error?
    var readUpTo = 0
    private(set) var sent: [ChatOutgoing] = []
    private(set) var readMarks: [Int] = []

    func loadNewest() async throws {
        if let error {
            throw error
        }
        info.title = "Loaded"
        if !pages.isEmpty {
            messages = pages.removeFirst()
        }
    }

    func loadEarlier() async throws {}

    func append(_ message: ChatMessage) {
        messages.append(message)
    }

    func replace(with messages: [ChatMessage]) {
        self.messages = messages
    }

    func send(_ message: ChatOutgoing) async throws -> String? {
        sent.append(message)
        let id = "sent-\(sent.count)"
        messages.append(ChatMessage(id: id, sender: ChatUser(id: "you", name: "You", avatarURL: nil), timestamp: Date(), text: message.text, isOwn: true))
        return id
    }

    func isAfterReadPosition(_ message: ChatMessage) -> Bool {
        (Int(message.id) ?? 0) > readUpTo
    }

    func markRead(upTo message: ChatMessage) -> (@MainActor () async throws -> Void)? {
        guard let id = Int(message.id), id > readUpTo else { return nil }
        readUpTo = id
        return { [weak self] in self?.readMarks.append(id) }
    }

    func reactors(of _: String, on _: String) -> [ChatReactor] {
        []
    }

    private struct Snapshot: Codable {
        let ids: [Int]
    }

    func snapshot() -> Data? {
        try? JSONEncoder().encode(Snapshot(ids: messages.compactMap { Int($0.id) }))
    }

    func restore(snapshot data: Data) {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        messages = snapshot.ids.map { message($0) }
    }
}

@MainActor
private final class FakeLiveAdapter: FakeAdapter, ChatLiveUpdating, ChatReferenceResolving {
    var onConnectionLost: ((Error?) -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var followCount = 0
    private(set) var isFollowing = false
    var referencedMessages: [String: ChatMessage] = [:]
    var unavailableReferences: Set<String> = []

    func startFollowing() async {
        followCount += 1
        isFollowing = true
    }

    func stopFollowing() {
        isFollowing = false
    }

    func push(_ pushed: ChatMessage) {
        append(pushed)
        onChange?()
    }
}

/// Messages 1–100 exist on the "network"; a window holds the message and the five after it.
@MainActor
private final class FakeWindowingAdapter: FakeAdapter, ChatWindowing, ChatCommanding {
    private(set) var hasLaterMessages = false
    private(set) var commands: [String] = []
    private var latest: [ChatMessage] = []

    override func loadNewest() async throws {
        try await super.loadNewest()
        latest = messages
    }

    func loadLater() async throws {}

    func showWindow(around messageId: String) async throws -> Bool {
        guard let id = Int(messageId), (1 ... 100).contains(id) else { return false }
        replace(with: (id ... id + 5).map { message($0) })
        hasLaterMessages = true
        return true
    }

    func showLatest() async throws {
        replace(with: latest)
        hasLaterMessages = false
    }

    func isCommand(_ text: String) -> Bool {
        text.hasPrefix("/")
    }

    func sendCommand(_ text: String, replyToId _: String?) async throws {
        commands.append(text)
    }
}

@MainActor
private final class FakeEditingAdapter: FakeAdapter, ChatEditing {
    var editError: Error?
    /// Off for a network whose copy of the edit arrives later.
    var appliesEdits = true
    private(set) var edits: [(id: String, text: String)] = []

    func editableText(of message: ChatMessage) -> String? {
        messages.first { $0.id == message.id && $0.isOwn }?.text
    }

    func edit(_ messageId: String, text: String) async throws {
        if let editError {
            throw editError
        }
        edits.append((messageId, text))
        guard appliesEdits else { return }
        replace(with: messages.map { $0.id == messageId ? ChatMessage(id: $0.id, sender: $0.sender, timestamp: $0.timestamp, text: text, isOwn: true, isEdited: true) : $0 })
    }
}

@MainActor
private final class FakeDeletingAdapter: FakeAdapter, ChatDeleting {
    var deleteError: Error?
    private(set) var deleted: [String] = []

    func canDelete(_ message: ChatMessage) -> Bool {
        message.isOwn
    }

    func delete(_ messageId: String) async throws {
        if let deleteError {
            throw deleteError
        }
        deleted.append(messageId)
        replace(with: messages.filter { $0.id != messageId })
    }
}

@MainActor
private final class FakeReactingAdapter: FakeAdapter, ChatReactionSending {
    let acceptsReactions = true

    func yourEmojis(on messageId: String) -> [String] {
        reactions[messageId]?.filter(\.includesYou).map(\.emoji) ?? []
    }

    func toggleReaction(_ emoji: String, on messageId: String) async throws {
        reactions[messageId] = [ChatReaction(emoji: emoji, count: 1, includesYou: true)]
    }
}

@MainActor
private final class FakeStickerAdapter: FakeAdapter, ChatStickerSending {
    let sticker = ChatSticker(id: "7", url: URL(string: "tgfile://file/document-7-full")!, format: .lottie, posterURL: nil, aspectRatio: 1, alt: "👋")
    var stickerError: Error?
    private(set) var sentStickers: [ChatSticker] = []
    private(set) var sentStickerReplies: [String?] = []

    func stickerSets() async throws -> [ChatStickerSet] {
        [ChatStickerSet(id: "recent", title: "Recent", cover: nil, count: 1, stickers: [sticker]), ChatStickerSet(id: "set-1", title: "Hands", cover: nil, count: 1, stickers: nil)]
    }

    func stickers(forEmoji emoji: String) async throws -> [ChatSticker] {
        emoji == "👋" ? [sticker] : []
    }

    func stickers(inSet id: String) async throws -> [ChatSticker] {
        id == "set-1" ? [sticker] : []
    }

    func send(sticker: ChatSticker, replyToId: String?) async throws -> String? {
        if let stickerError {
            throw stickerError
        }
        sentStickers.append(sticker)
        sentStickerReplies.append(replyToId)
        let id = "sticker-\(sentStickers.count)"
        append(ChatMessage(id: id, sender: ChatUser(id: "you", name: "You", avatarURL: nil), timestamp: Date(), text: nil, embeds: [.sticker(sticker)], isOwn: true))
        return id
    }
}

@MainActor
private final class FakeForwardingAdapter: FakeAdapter, ChatForwarding {
    private(set) var forwarded: [String] = []

    func forwardReference(for message: ChatMessage) -> String? {
        "ref-\(message.id)"
    }

    func forward(reference: String) async throws -> String? {
        forwarded.append(reference)
        let id = "forward-\(forwarded.count)"
        append(ChatMessage(id: id, sender: ChatUser(id: "you", name: "You", avatarURL: nil), timestamp: Date(), text: "Message 1", isOwn: true, forwardedFrom: ChatForwardOrigin(name: "Ada")))
        return id
    }
}

@MainActor
private final class FakeVoiceAdapter: FakeAdapter, ChatVoiceSending {
    var onSend: (() async -> Void)?
    private(set) var sentVoices: [ChatVoiceNote] = []
    private(set) var sentVoiceReplies: [String?] = []

    func send(voice: ChatVoiceNote, replyToId: String?) async throws -> String? {
        await onSend?()
        sentVoices.append(voice)
        sentVoiceReplies.append(replyToId)
        let id = "voice-\(sentVoices.count)"
        append(ChatMessage(id: id, sender: ChatUser(id: "you", name: "You", avatarURL: nil), timestamp: Date(), text: nil, embeds: [.voice(previewId: id, duration: voice.duration, waveform: voice.waveform)], isOwn: true))
        return id
    }
}

@MainActor
private final class FakeReceiptsAdapter: FakeAdapter, ChatReadReceipts {
    var seenUpTo = 0

    func receipt(for message: ChatMessage) -> ChatReceipt? {
        (Int(message.id) ?? 0) <= seenUpTo ? .seen : .sent
    }
}

@MainActor
private final class FakeUnseenReactionsAdapter: FakeAdapter, ChatUnseenReactions {
    var unseen: [String] = []
    var earlierPages: [[ChatMessage]] = []
    private var pending: Set<String> = []
    private(set) var seenSends: [[String]] = []

    var unseenReactionMessageIds: [String] {
        unseen
    }

    override var hasEarlierMessages: Bool {
        get { !earlierPages.isEmpty }
        set {}
    }

    override func loadEarlier() async throws {
        guard !earlierPages.isEmpty else { return }
        replace(with: earlierPages.removeFirst() + messages)
    }

    func markReactionsSeen(on messageIds: Set<String>) -> (@MainActor () async throws -> Void)? {
        unseen.removeAll { messageIds.contains($0) }
        pending.formUnion(messageIds)
        return { [weak self] in
            guard let self, !pending.isEmpty else { return }
            seenSends.append(pending.sorted())
            pending = []
        }
    }
}
