//
//  ZenNIO.swift
//  ZenNIO
//
//  Created by admin on 20/12/2018.
//

import NIO
import NIOHTTP1
import NIOHTTP2
import NIOSSL

public class ZenNIO {
    
    private var sslContext: NIOSSLContext? = nil
    private var httpProtocol: HttpProtocol = .v1
    
    public let port: Int
    public let host: String
    public var htdocsPath: String = ""
    static var router = Router()
    static var sessions = HttpSession()
    static var cors = false
    static var session = false
    
    public init(
        host: String = "::1",
        port: Int = 8888,
        router: Router = Router()
    ) {
        self.host = host
        self.port = port
        ZenNIO.router = router
    }
    
    private let cipherSuites = "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-CBC-SHA384:ECDHE-ECDSA-AES256-CBC-SHA:ECDHE-ECDSA-AES128-CBC-SHA256:ECDHE-ECDSA-AES128-CBC-SHA:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-CBC-SHA384:ECDHE-RSA-AES128-CBC-SHA256:ECDHE-RSA-AES128-CBC-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA"
    
    public func addWebroot(path: String = "webroot") {
        htdocsPath = path
        ZenNIO.router.initFolder(webroot: path)
    }
    
    public func addSSL(certFile: String, keyFile: String, http: HttpProtocol = .v1) throws {
        self.httpProtocol = http
        let config = TLSConfiguration.forServer(
            certificateChain: [.file(certFile)],
            privateKey: .file(keyFile),
            cipherSuites: cipherSuites,
            minimumTLSVersion: .tlsv11,
            maximumTLSVersion: .tlsv12,
            certificateVerification: .noHostnameVerification,
            trustRoots: .default,
            applicationProtocols: [httpProtocol.rawValue]
        )
        sslContext = try! NIOSSLContext(configuration: config)
    }
    
    public func addCORS() {
        ZenNIO.cors = true
    }
    
    public func addAuthentication(handler: @escaping Login) {
        ZenNIO.session = true
        ZenIoC.shared.register { AuthenticationProvider() as AuthenticationProtocol }
        Authentication(handler: handler).makeRoutesAndHandlers(router: ZenNIO.router)
    }

    public func addFilter(method: HTTPMethod, url: String) {
        ZenNIO.router.addFilter(method: method, url: url)
    }

    static func getRoute(request: inout HttpRequest) -> Route? {
        return self.router.getRoute(request: &request)
    }
    
    public func start() throws {
        let threadPool = NIOThreadPool(numberOfThreads: System.coreCount)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        defer {
            try! threadPool.syncShutdownGracefully()
            try! group.syncShutdownGracefully()
        }
        
        var fileIO: NonBlockingFileIO? = nil
        if !htdocsPath.isEmpty {
            threadPool.start()
            fileIO = NonBlockingFileIO(threadPool: threadPool)
        }
        
        let bootstrap = ServerBootstrap(group: group)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        
        
        // Set the handlers that are applied to the accepted Channels
        if let sslContext = self.sslContext {
            let sslHandler = try! NIOSSLServerHandler(context: sslContext)
            if httpProtocol == .v1 {
                _ = bootstrap.childChannelInitializer { channel in
                    return channel.pipeline.addHandler(sslHandler).flatMap {
                        channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                            channel.pipeline.addHandler(ServerHandler(fileIO: fileIO, htdocsPath: self.htdocsPath))
                        }
                    }
                }
            } else {
                // Set the handlers that are applied to the accepted Channels
                _ = bootstrap.childChannelInitializer { channel in
                    return channel.pipeline.addHandler(sslHandler).flatMap {
                        channel.configureHTTP2Pipeline(mode: .server) { (streamChannel, streamID) -> EventLoopFuture<Void> in
                            streamChannel.pipeline.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID)).flatMap { () -> EventLoopFuture<Void> in
                                streamChannel.pipeline.addHandler(ServerHandler(fileIO: fileIO, htdocsPath: self.htdocsPath))
                            }
                        }.flatMap { (_: HTTP2StreamMultiplexer) in
                            channel.pipeline.addHandler(ErrorHandler())
                        }
                    }
                }
            }
        } else {
            _ = bootstrap.childChannelInitializer { channel in
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(ServerHandler(fileIO: fileIO, htdocsPath: self.htdocsPath))
                }
            }
        }
        
        // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
        _ = bootstrap.childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        
        let channel = try { () -> Channel in
            return try bootstrap.bind(host: host, port: port).wait()
            }()
        
        guard let localAddress = channel.localAddress else {
            fatalError("Address was unable to bind.")
        }
        
        let http = sslContext != nil ? "HTTPS" : "HTTP"
        print("\(http) ZenNIO started on\(localAddress)")
        
        // This will never unblock as we don't close the ServerChannel
        try channel.closeFuture.wait()
        
        print("ZenNIO closed")
    }
}

/// Wrapping Swift.debugPrint() within DEBUG flag
func debugPrint(_ object: Any) {
    // Only allowing in DEBUG mode
    #if DEBUG
    Swift.print(object)
    #endif
}

final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Never
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("Server received error: \(error)")
        context.close(promise: nil)
    }
}

