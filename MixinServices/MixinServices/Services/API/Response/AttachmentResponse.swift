import Foundation

public struct AttachmentResponse: Codable {
    
    public let attachmentId: String
    public let uploadUrl: String?
    public let viewUrl: String?
    public let createdAt: String?
    
    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case uploadUrl = "upload_url"
        case viewUrl = "view_url"
        case createdAt = "created_at"
    }
    
}
