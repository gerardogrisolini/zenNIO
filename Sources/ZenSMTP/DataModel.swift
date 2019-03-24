//
//  DataModel.swift
//  ZenSMTP
//
//  Created by admin on 01/03/2019.
//

import Foundation
import NIOSSL

enum SMTPRequest {
    case sayHello(serverName: String)
    case beginAuthentication
    case authUser(String)
    case authPassword(String)
    case mailFrom(String)
    case recipient(String)
    case data
    case transferData(Email)
    case quit
}

enum SMTPResponse {
    case ok(Int, String)
    case error(String)
}

public struct ServerConfiguration {
    public var hostname: String
    public var port: Int
    public var username: String
    public var password: String
    public var cert: NIOSSLCertificateSource?
    public var key: NIOSSLPrivateKeySource?
}

public struct Attachment {
    public var fileName: String
    public var contentType: String
    public var data: Data
}

public struct Email {
    var fromName: String?
    var fromEmail: String
    var toName: String?
    var toEmail: String
    
    var subject: String
    var body: String
    var attachments: [Attachment]
}
