import Foundation
import GRDB
import MixinServices

public protocol DeletableMessage {
    var messageId: String { get }
    var conversationId: String { get }
    var category: String { get }
    var mediaUrl: String? { get }
}

extension Message: DeletableMessage {
    
}

extension MessageItem: DeletableMessage {
    
}

public final class DeleteMessageWork: Work {
    
    public enum Attachment: Codable {
        case media(category: String, filename: String)
        case transcript
    }
    
    public enum Error: Swift.Error {
        case invalidContext
    }
    
    public static let willDeleteNotification = Notification.Name("one.mixin.services.DeleteMessageWork.willDelete")
    public static let messageIdUserInfoKey = "msg"
    
    let messageId: String
    let conversationId: String
    let attachment: Attachment?
    
    @Synchronized(value: false)
    private var hasDatabaseRecordDeleted: Bool
    
    public convenience init(message: DeletableMessage) {
        let attachment: Attachment?
        if ["_IMAGE", "_DATA", "_AUDIO", "_VIDEO"].contains(where: message.category.hasSuffix), let filename = message.mediaUrl {
            attachment = .media(category: message.category, filename: filename)
        } else if message.category.hasSuffix("_TRANSCRIPT") {
            attachment = .transcript
        } else {
            attachment = nil
        }
        self.init(messageId: message.messageId, conversationId: message.conversationId, attachment: attachment)
    }
    
    public init(messageId: String, conversationId: String, attachment: Attachment?) {
        self.messageId = messageId
        self.conversationId = conversationId
        self.attachment = attachment
        super.init(id: "delete-message-\(messageId)", state: .ready)
    }
    
    public override func main() throws {
        if !hasDatabaseRecordDeleted {
            MessageDAO.shared.delete(id: messageId, conversationId: conversationId)
        }
        switch attachment {
        case let .media(category, filename):
            AttachmentContainer.removeMediaFiles(mediaUrl: filename, category: category)
        case .transcript:
            let transcriptId = messageId
            let childMessageIds = TranscriptMessageDAO.shared.childrenMessageIds(transcriptId: transcriptId)
            let jobIds = childMessageIds.map { transcriptMessageId in
                AttachmentDownloadJob.jobId(transcriptId: transcriptId, messageId: transcriptMessageId)
            }
            for id in jobIds {
                ConcurrentJobQueue.shared.cancelJob(jobId: id)
            }
            AttachmentContainer.removeAll(transcriptId: transcriptId)
            TranscriptMessageDAO.shared.deleteTranscriptMessages(with: transcriptId)
        case .none:
            break
        }
    }
    
}

extension DeleteMessageWork: PersistableWork {
    
    private struct Context: Codable {
        let messageId: String
        let conversationId: String
        let attachment: Attachment?
    }
    
    public static let typeIdentifier: String = "delete_message"
    
    public var context: Data? {
        let context = Context(messageId: messageId,
                              conversationId: conversationId,
                              attachment: attachment)
        return try? JSONEncoder.default.encode(context)
    }
    
    public var priority: PersistedWork.Priority {
        .medium
    }
    
    public convenience init(id: String, context: Data?) throws {
        guard
            let context = context,
            let context = try? JSONDecoder.default.decode(Context.self, from: context)
        else {
            throw Error.invalidContext
        }
        self.init(messageId: context.messageId,
                  conversationId: context.conversationId,
                  attachment: context.attachment)
    }
    
    public func persistenceDidComplete() {
        NotificationCenter.default.post(onMainThread: Self.willDeleteNotification,
                                        object: self,
                                        userInfo: [Self.messageIdUserInfoKey: messageId])
        MessageDAO.shared.delete(id: messageId, conversationId: conversationId)
        hasDatabaseRecordDeleted = true
        Logger.general.debug(category: "DeleteMessageWork", message: "\(messageId) Message deleted from database")
    }
    
}
