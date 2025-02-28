//
//  RouteServer.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2018-10-24.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2019 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

import NIO
import NIOHTTP1
import NIOSSL
import Foundation

var sharedNonBlockingFileIO: NonBlockingFileIO = {
	let threadPool = NIOThreadPool(numberOfThreads: NonBlockingFileIO.defaultThreadPoolSize)
	threadPool.start()
	return NonBlockingFileIO(threadPool: threadPool)
}()

/// Routes which have been bound to a port and have started listening for connections.
public protocol ListeningRoutes {
	/// Stop listening for requests
	@discardableResult
	func stop() -> ListeningRoutes
	/// Wait, perhaps forever, until the routes have stopped listening for requests.
	func wait() throws
}

/// Routes which have been bound to an address but are not yet listening for requests.
public protocol BoundRoutes {
	/// The address the server is bound to.
	var address: SocketAddress { get }
	/// Start listening
	func listen() throws -> ListeningRoutes
}

class NIOBoundRoutes: BoundRoutes {
	private let childGroup: EventLoopGroup
	let acceptGroup: MultiThreadedEventLoopGroup
	private let channel: Channel
	public let address: SocketAddress
	init(registry: Routes<HTTPRequest, HTTPOutput>,
		 address: SocketAddress,
		 threadGroup: EventLoopGroup?,
		 tls: TLSConfiguration?) throws {
		
		let ag = MultiThreadedEventLoopGroup(numberOfThreads: 1)
		acceptGroup = ag
		childGroup = threadGroup ?? ag
		let finder = try RouteFinderDual(registry)
		self.address = address
		
		let sslContext: NIOSSLContext?
		if let tls = tls {
			sslContext = try NIOSSLContext(configuration: tls)
		} else {
			sslContext = nil
		}
		var bs = ServerBootstrap(group: acceptGroup, childGroup: childGroup)
			.serverChannelOption(ChannelOptions.backlog, value: 256)
			.serverChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
			.serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
		if threadGroup == nil {
			bs = bs.serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEPORT), value: 1)
		}
		channel = try bs
			.childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
			.childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
			.childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
			.childChannelOption(ChannelOptions.autoRead, value: true)
			.childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
			.childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator(minimum: 1024, initial: 4096, maximum: 65536))
			.childChannelInitializer {
				channel in
				NIOBoundRoutes.configureHTTPServerPipeline(pipeline: channel.pipeline, sslContext: sslContext)
				.flatMap {
					_ in
					channel.pipeline.addHandler(NIOHTTPHandler(finder: finder, isTLS: sslContext != nil), name: "NIOHTTPHandler")
				}
			}.bind(to: address).wait()
	}
	public func listen() throws -> ListeningRoutes {
		return NIOListeningRoutes(channel: channel)
	}
	private static func configureHTTPServerPipeline(pipeline: ChannelPipeline, sslContext: NIOSSLContext?) -> EventLoopFuture<Void> {
		var handlers: [ChannelHandler] = []
		if let sslContext = sslContext {
			let handler = NIOSSLServerHandler(context: sslContext)
			handlers.append(handler)
			handlers.append(SSLFileRegionHandler())
		}
		let responseEncoder = HTTPResponseEncoder()
		let requestDecoder = HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)

		return pipeline.addHandlers(handlers)
			.flatMap { pipeline.addHandler(responseEncoder, name: "HTTPResponseEncoder", position: .last) }
			.flatMap { pipeline.addHandler(ByteToMessageHandler(requestDecoder), name: "HTTPRequestDecoder", position: .last) }
			.flatMap { pipeline.addHandler(HTTPServerPipelineHandler(), name: "HTTPServerPipelineHandler", position: .last) }
			.flatMap { pipeline.addHandler(HTTPServerProtocolErrorHandler(), name: "HTTPServerProtocolErrorHandler", position: .last) }
	}
}

private final class SSLFileRegionHandler: ChannelOutboundHandler {
	typealias OutboundIn = IOData
	typealias OutboundOut = IOData
	
	private static let fileIO = sharedNonBlockingFileIO
	private typealias BufferedWrite = (data: IOData, promise: EventLoopPromise<Void>?)
	private var buffer = MarkedCircularBuffer<BufferedWrite>(initialCapacity: 96)
	
	func write(context: ChannelHandlerContext,
			   data: NIOAny,
			   promise: EventLoopPromise<Void>?) {
		buffer.append((data: unwrapOutboundIn(data), promise: promise))
	}
	func flush(context: ChannelHandlerContext) {
		buffer.mark()
		flushBuffer(context: context)
	}
	func flushBuffer(context: ChannelHandlerContext) {
		guard buffer.hasMark else {
			return context.flush()
		}
		guard let item = buffer.popFirst() else {
			return
		}
		let unwrapped = item.data
		let promise = item.promise
		
		switch unwrapped {
		case .fileRegion(let region):
			SSLFileRegionHandler.fileIO.readChunked(fileRegion: region,
													allocator: ByteBufferAllocator(),
													eventLoop: context.eventLoop) {
														context.writeAndFlush(self.wrapOutboundOut(.byteBuffer($0)))
			}.always {
				_ in
				self.flushBuffer(context: context)
			}.cascade(to: promise)
		case .byteBuffer(_):
			context.write(wrapOutboundOut(unwrapped), promise: promise)
			flushBuffer(context: context)
		}
	}
}

class NIOListeningRoutes: ListeningRoutes {
	private let channel: Channel
	private let f: EventLoopFuture<Void>
	private static var globalInitialized: Bool = {
		var sa = sigaction()
		// !FIX! re-evaluate which of these are required
	#if os(Linux)
		sa.__sigaction_handler.sa_handler = SIG_IGN
	#else
		sa.__sigaction_u.__sa_handler = SIG_IGN
	#endif
		sa.sa_flags = 0
		sigaction(SIGPIPE, &sa, nil)
		var rlmt = rlimit()
	#if os(Linux)
		getrlimit(Int32(RLIMIT_NOFILE.rawValue), &rlmt)
		rlmt.rlim_cur = rlmt.rlim_max
		setrlimit(Int32(RLIMIT_NOFILE.rawValue), &rlmt)
	#else
		getrlimit(RLIMIT_NOFILE, &rlmt)
		rlmt.rlim_cur = rlim_t(OPEN_MAX)
		setrlimit(RLIMIT_NOFILE, &rlmt)
	#endif
		return true
	}()
	init(channel: Channel) {
		_ = NIOListeningRoutes.globalInitialized
		self.channel = channel
		f = channel.closeFuture
	}
	@discardableResult
	public func stop() -> ListeningRoutes {
		channel.close(promise: nil)
		return self
	}
	public func wait() throws {
		try f.wait()
	}
}

public extension Routes where InType == HTTPRequest, OutType == HTTPOutput {
	func bind(port: Int, tls: TLSConfiguration? = nil) throws -> BoundRoutes {
		let address = try SocketAddress(ipAddress: "0.0.0.0", port: port)
		return try bind(address: address, tls: tls)
	}
	func bind(address: SocketAddress, tls: TLSConfiguration? = nil) throws -> BoundRoutes {
		return try NIOBoundRoutes(registry: self,
								  address: address,
								  threadGroup: MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount),
								  tls: tls)
	}
	func bind(count: Int, address: SocketAddress, tls: TLSConfiguration? = nil) throws -> [BoundRoutes] {
		if count == 1 {
			return [try bind(address: address)]
		}
		return try (0..<count).map { _ in
			return try NIOBoundRoutes(registry: self,
									  address: address,
									  threadGroup: nil,
									  tls: tls)
		}
	}
}

extension HTTPMethod {
	static var allCases: [HTTPMethod] {
		return [
		.GET,.PUT,.ACL,.HEAD,.POST,.COPY,.LOCK,.MOVE,.BIND,.LINK,.PATCH,
		.TRACE,.MKCOL,.MERGE,.PURGE,.NOTIFY,.SEARCH,.UNLOCK,.REBIND,.UNBIND,
		.REPORT,.DELETE,.UNLINK,.CONNECT,.MSEARCH,.OPTIONS,.PROPFIND,.CHECKOUT,
		.PROPPATCH,.SUBSCRIBE,.MKCALENDAR,.MKACTIVITY,.UNSUBSCRIBE
		]
	}
	var name: String {
		switch self {
		case .GET:
			return "GET"
		case .PUT:
			return "PUT"
		case .ACL:
			return "ACL"
		case .HEAD:
			return "HEAD"
		case .POST:
			return "POST"
		case .COPY:
			return "COPY"
		case .LOCK:
			return "LOCK"
		case .MOVE:
			return "MOVE"
		case .BIND:
			return "BIND"
		case .LINK:
			return "LINK"
		case .PATCH:
			return "PATCH"
		case .TRACE:
			return "TRACE"
		case .MKCOL:
			return "MKCOL"
		case .MERGE:
			return "MERGE"
		case .PURGE:
			return "PURGE"
		case .NOTIFY:
			return "NOTIFY"
		case .SEARCH:
			return "SEARCH"
		case .UNLOCK:
			return "UNLOCK"
		case .REBIND:
			return "REBIND"
		case .UNBIND:
			return "UNBIND"
		case .REPORT:
			return "REPORT"
		case .DELETE:
			return "DELETE"
		case .UNLINK:
			return "UNLINK"
		case .CONNECT:
			return "CONNECT"
		case .MSEARCH:
			return "MSEARCH"
		case .OPTIONS:
			return "OPTIONS"
		case .PROPFIND:
			return "PROPFIND"
		case .CHECKOUT:
			return "CHECKOUT"
		case .PROPPATCH:
			return "PROPPATCH"
		case .SUBSCRIBE:
			return "SUBSCRIBE"
		case .MKCALENDAR:
			return "MKCALENDAR"
		case .MKACTIVITY:
			return "MKACTIVITY"
		case .UNSUBSCRIBE:
			return "UNSUBSCRIBE"
		case .SOURCE:
			return "SOURCE"
		case .RAW(let value):
			return value
		}
	}
}

extension HTTPMethod: Hashable {
	public func hash(into hasher: inout Hasher) {
		hasher.combine(name.hashValue)
	}
}

extension String {
	var method: HTTPMethod {
		switch self {
		case "GET":
			return .GET
		case "PUT":
			return .PUT
		case "ACL":
			return .ACL
		case "HEAD":
			return .HEAD
		case "POST":
			return .POST
		case "COPY":
			return .COPY
		case "LOCK":
			return .LOCK
		case "MOVE":
			return .MOVE
		case "BIND":
			return .BIND
		case "LINK":
			return .LINK
		case "PATCH":
			return .PATCH
		case "TRACE":
			return .TRACE
		case "MKCOL":
			return .MKCOL
		case "MERGE":
			return .MERGE
		case "PURGE":
			return .PURGE
		case "NOTIFY":
			return .NOTIFY
		case "SEARCH":
			return .SEARCH
		case "UNLOCK":
			return .UNLOCK
		case "REBIND":
			return .REBIND
		case "UNBIND":
			return .UNBIND
		case "REPORT":
			return .REPORT
		case "DELETE":
			return .DELETE
		case "UNLINK":
			return .UNLINK
		case "CONNECT":
			return .CONNECT
		case "MSEARCH":
			return .MSEARCH
		case "OPTIONS":
			return .OPTIONS
		case "PROPFIND":
			return .PROPFIND
		case "CHECKOUT":
			return .CHECKOUT
		case "PROPPATCH":
			return .PROPPATCH
		case "SUBSCRIBE":
			return .SUBSCRIBE
		case "MKCALENDAR":
			return .MKCALENDAR
		case "MKACTIVITY":
			return .MKACTIVITY
		case "UNSUBSCRIBE":
			return .UNSUBSCRIBE
		default:
			return .RAW(value: self)
		}
	}
	var splitMethod: (HTTPMethod?, String) {
		if let i = range(of: "://") {
			return (String(self[self.startIndex..<i.lowerBound]).method, String(self[i.upperBound...]))
		}
		return (nil, self)
	}
}

public extension Routes {
	var GET: Routes<InType, OutType> { return method(.GET) }
	var POST: Routes { return method(.POST) }
	var PUT: Routes { return method(.PUT) }
	var DELETE: Routes { return method(.DELETE) }
	var OPTIONS: Routes { return method(.OPTIONS) }
	func method(_ method: HTTPMethod, _ methods: HTTPMethod...) -> Routes {
		let methods = [method] + methods
		return .init(.init(routes:
			registry.routes.flatMap {
				route in
				return methods.map {
					($0.name + "://" + route.0.splitMethod.1, route.1)
				}
			}
		))
	}
}
