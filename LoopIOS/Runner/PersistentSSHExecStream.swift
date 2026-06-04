//
//  PersistentSSHExecStream.swift
//  Loop
//
//  A streaming `exec` channel multiplexed over a live `PersistentSSHConnection`.
//
//  Where `SSHSkill.runCommand` opens a *fresh* TCP + handshake + auth per command
//  (the per-poll cost the OpenClaw backend currently pays on every dispatch and
//  every run-log read) and resolves only once the command exits, this opens one
//  `session`+`exec` child channel on the connection that's already warm and
//  delivers stdout/stderr *incrementally* as the remote produces them. That's the
//  basis for streaming an `openclaw agent` turn token-by-token instead of
//  detaching it and polling a `/tmp` log over repeated handshakes.
//
//  The exec request + streaming reads + exit-status handling mirror the patterns
//  already in the codebase: the exec request from `SSHSkill`'s one-shot
//  `SSHExecHandler`, the incremental `channelRead` + `allowRemoteHalfClosure` +
//  exit reporting from `SSHTerminalSession`'s shell handler.
//
//  Threading: callbacks fire on the connection's single NIO event loop — NOT the
//  main thread. Callers that touch UI or main-thread-confined model state (the
//  MessagingVC streaming bubble, OpenClawConversationStore's main-posted change
//  notifications) MUST hop to main first. See the MessagingVC main-thread
//  invariant.
//

import Foundation
import NIOCore
import NIOSSH
import os

extension PersistentSSHConnection {

    /// A live command running over the persistent connection. Retain it for the
    /// duration of the turn; `cancel()` (or deinit) closes the exec channel,
    /// terminating the remote command.
    final class ExecStream {
        private let channel: Channel
        private let lock = NSLock()
        private var closed = false

        fileprivate init(channel: Channel) { self.channel = channel }

        /// Closes the exec channel, sending EOF / killing the remote command.
        /// Idempotent.
        func cancel() {
            lock.lock()
            let alreadyClosed = closed
            closed = true
            lock.unlock()
            guard !alreadyClosed else { return }
            channel.close(promise: nil)
        }

        deinit { cancel() }
    }

    /// Runs `command` over a fresh `session`+`exec` child channel on this
    /// connection, streaming output as it arrives.
    ///
    /// - Parameters:
    ///   - onStdout/onStderr: incremental output chunks (decoded by the caller —
    ///     a chunk may split a UTF-8 sequence, so accumulate before decoding).
    ///   - onExit: the remote exit code (nil if the channel closed without one),
    ///     delivered exactly once when the command finishes or the channel drops.
    /// - Returns: a handle to cancel the running command.
    ///
    /// Reuses the warm TCP + auth — no per-call SSH handshake. All callbacks fire
    /// on the connection's event loop; hop to main before touching UI state.
    func execStream(_ command: String,
                    onStdout: @escaping (Data) -> Void,
                    onStderr: @escaping (Data) -> Void,
                    onExit: @escaping (Int32?) -> Void) async throws -> ExecStream {
        let root = try await rootChannel()

        // Resolve the SSH handler and open the child channel from inside the
        // pipeline future's callback, which fires on the connection's single event
        // loop — `createChannel` must be invoked there (same pattern as
        // `SSHTunnelForwarder.bridge`). Awaiting a raw handler off-loop and calling
        // `createChannel` from the continuation thread would be unsafe.
        let child = try await root.pipeline.handler(type: NIOSSHHandler.self)
            .flatMap { sshHandler -> EventLoopFuture<Channel> in
                let promise = root.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) { child, channelType in
                    guard case .session = channelType else {
                        return child.eventLoop.makeFailedFuture(SSHSkillError.unexpectedChannelType)
                    }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            StreamingExecHandler(command: command,
                                                 onStdout: onStdout,
                                                 onStderr: onStderr,
                                                 onExit: onExit))
                    }
                }
                return promise.futureResult
            }
            .get()
        return ExecStream(channel: child)
    }
}

// MARK: - Channel handler

/// Sends the exec request on `channelActive`, streams stdout/stderr chunks to the
/// callbacks as they arrive, and reports the exit code exactly once when the
/// channel goes inactive. Mirrors `SSHExecHandler` (exec request) and
/// `SSHTerminalChannelHandler` (incremental reads + exit reporting).
private final class StreamingExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private static let log = Logger(subsystem: "com.bhat.intel", category: "PersistentSSHExec")

    private let command: String
    private let onStdout: (Data) -> Void
    private let onStderr: (Data) -> Void
    private let onExit: (Int32?) -> Void
    private var exitCode: Int32?
    private var finished = false

    init(command: String,
         onStdout: @escaping (Data) -> Void,
         onStderr: @escaping (Data) -> Void,
         onExit: @escaping (Int32?) -> Void) {
        self.command = command
        self.onStdout = onStdout
        self.onStderr = onStderr
        self.onExit = onExit
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        Self.log.info("exec-stream: channel active; sending exec request")
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(request, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else { return }
        let chunk = Data(bytes)
        switch channelData.type {
        case .channel: onStdout(chunk)
        case .stdErr:  onStderr(chunk)
        default:       break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitCode = Int32(status.exitStatus)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish()
    }

    /// Delivers the exit callback exactly once. Runs on the event loop, so the
    /// `finished` guard needs no locking.
    private func finish() {
        guard !finished else { return }
        finished = true
        onExit(exitCode)
    }
}
