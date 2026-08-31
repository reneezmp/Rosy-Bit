import XCTest
@testable import RosyBit

final class ConversationStoreTests: XCTestCase {

    func testConversationTitleIsCompactAndSingleLine() {
        XCTAssertEqual(
            Conversation.title(from: "  A title\nwith   unusual spacing  "),
            "A title with unusual spacing")
        XCTAssertEqual(Conversation.title(from: "   "), "New conversation")
        XCTAssertLessThanOrEqual(
            Conversation.title(from: String(repeating: "word ", count: 20)).count,
            42)
    }

    @MainActor
    func testAskBarTurnBecomesSelectedConversationWithoutRegeneration() {
        let store = ConversationStore()
        let id = store.continueFromAskBar(
            question: "What does susurrus mean?",
            answer: "A whispering sound.")

        XCTAssertEqual(store.selectedID, id)
        XCTAssertEqual(store.conversations.count, 1)
        XCTAssertEqual(store.selectedConversation?.messages.count, 2)
        XCTAssertEqual(store.selectedConversation?.messages[0].content,
                       "What does susurrus mean?")
        XCTAssertTrue(store.selectedConversation?.messages[0].payloadContent
            .hasPrefix("[Timestamp:") == true)
        XCTAssertEqual(store.selectedConversation?.messages[1].content,
                       "A whispering sound.")
        XCTAssertFalse(store.isGenerating)
    }

    @MainActor
    func testDeletingSelectedConversationSelectsNextSession() {
        let store = ConversationStore()
        let first = store.newConversation()
        let second = store.newConversation()
        XCTAssertEqual(store.selectedID, second)

        store.delete(second)

        XCTAssertEqual(store.selectedID, first)
        XCTAssertEqual(store.conversations.count, 1)
    }

    @MainActor
    func testDeletingMessageTrimsDependentConversationBranch() {
        let store = ConversationStore()
        let id = store.continueFromAskBar(question: "First?", answer: "First answer")
        guard let userID = store.selectedConversation?.messages.first?.id else {
            return XCTFail("Missing user message")
        }

        store.deleteMessageAndFollowing(userID)

        XCTAssertEqual(store.selectedID, id)
        XCTAssertTrue(store.selectedConversation?.messages.isEmpty == true)
        XCTAssertEqual(store.selectedConversation?.title, "New conversation")
    }

    @MainActor
    func testRecentContextKeepsNewestTurnAndDropsOldBulk() {
        let old = ConversationMessage(
            role: .user, content: String(repeating: "old ", count: 2_000))
        let oldAnswer = ConversationMessage(
            role: .assistant, content: String(repeating: "answer ", count: 2_000))
        let latest = ConversationMessage(role: .user, content: "What about now?")

        let context = ConversationStore.recentContext(from: [old, oldAnswer, latest])

        XCTAssertEqual(context.last?.id, latest.id)
        XCTAssertFalse(context.contains(where: { $0.id == old.id }))
    }
}
