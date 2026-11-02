import Foundation
import Testing

private let id = "01a189a2-372e-7842-be67-52651835ab46"

@Test func aBareLinkOrWordsThatOnlyPointAtItAddTheChat() {
    for text in ["codex://threads/\(id)", "find codex thread codex://threads/\(id)", "this chat: <codex://threads/\(id)>",
                 "Hey, add the chat (codex://thread/\(id))."] {
        #expect(CodexChatLink.threadID(in: text) == id, "\(text)")
        #expect(CodexChatLink.message(in: text) == nil, "\(text)")
    }
}

@Test func wordsThatAskForMoreGoToTheChatAsWritten() {
    for text in ["continue here: codex://threads/\(id)", "codex://threads/\(id) now pull Open-H3 and time it"] {
        #expect(CodexChatLink.threadID(in: text) == id)
        #expect(CodexChatLink.message(in: text) == text)
    }
}

@Test func textWithNoOrSeveralChatsIsANewTask() {
    #expect(CodexChatLink.threadID(in: "add services to the stack") == nil)
    #expect(CodexChatLink.threadID(in: "compare codex://threads/one with codex://threads/two") == nil)
    #expect(CodexChatLink.threadID(in: "codex://threads/") == nil)
    #expect(CodexChatLink.threadID(in: "codex://threads/a/b") == nil)
    // The same chat named twice is still one chat.
    #expect(CodexChatLink.threadID(in: "codex://threads/\(id) and again codex://threads/\(id)") == id)
}
