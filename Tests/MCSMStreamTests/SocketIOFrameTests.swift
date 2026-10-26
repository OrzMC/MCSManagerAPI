//
//  SocketIOFrameTests.swift
//  MCSMStreamTests
//
//  帧编解码：这些字符串都是面板/节点实际会发的形状（Engine.IO v4 + Socket.IO v5）。
//

import Testing

@testable import MCSMStream

@Suite("Socket.IO 帧编解码")
struct SocketIOFrameTests {

    @Test("握手 / 心跳 / 连接包")
    func controlPackets() {
        #expect(SocketIOFrame.decode("0{\"sid\":\"abc\",\"pingInterval\":25000}") == .open("{\"sid\":\"abc\",\"pingInterval\":25000}"))
        #expect(SocketIOFrame.decode("2") == .ping)
        #expect(SocketIOFrame.decode("3") == .pong)
        #expect(SocketIOFrame.decode("40") == .connected)
        #expect(SocketIOFrame.decode("41") == .disconnected)
        #expect(SocketIOFrame.decode("1") == .close)
        #expect(SocketIOFrame.decode("44{\"message\":\"unauthorized\"}") == .connectError("{\"message\":\"unauthorized\"}"))
    }

    @Test("业务事件：取名字与 data 外壳")
    func eventDecoding() {
        let auth = SocketIOFrame.decode("42[\"stream/auth\",{\"data\":true}]")
        #expect(auth == SocketIOFrame.event(name: "stream/auth", dataJSON: "{\"data\":true}"))
        #expect(auth.authAccepted == true)

        let rejected = SocketIOFrame.decode("42[\"stream/auth\",{\"data\":false}]")
        #expect(rejected.authAccepted == false)

        let stdout = SocketIOFrame.decode(
            "42[\"instance/stdout\",{\"data\":{\"instanceUuid\":\"u1\",\"text\":\"[12:00:00] Done\\r\\n\"}}]"
        )
        #expect(stdout.stdoutText == "[12:00:00] Done\r\n")

        let stopped = SocketIOFrame.decode("42[\"instance/stopped\",{\"data\":{\"instanceUuid\":\"u1\"}}]")
        #expect(stopped.instanceLifecycle == "stopped")
        #expect(SocketIOFrame.decode("42[\"instance/opened\",{}]").instanceLifecycle == "opened")
        #expect(SocketIOFrame.decode("42[\"instance/failure\",{}]").instanceLifecycle == "failure")
    }

    @Test("不是我们的事件时取不到值")
    func unrelatedEvent() {
        let frame = SocketIOFrame.decode("42[\"something/else\",{\"data\":true}]")
        #expect(frame.authAccepted == nil)
        #expect(frame.stdoutText == nil)
        #expect(frame.instanceLifecycle == nil)
    }

    @Test("怪帧不崩：空串 / 半截 JSON / 二进制前缀 / 没有参数")
    func malformedFrames() {
        let empty = SocketIOFrame.decode("")
        #expect(empty == SocketIOFrame.unknown(""))

        let halfJSON = SocketIOFrame.decode("42[")
        #expect(halfJSON == SocketIOFrame.unknown("["))

        let noArgs = SocketIOFrame.decode(#"42["stream/auth"]"#)
        #expect(noArgs == SocketIOFrame.event(name: "stream/auth", dataJSON: "null"))

        let binary = SocketIOFrame.decode(#"451-["binary"]"#)
        #expect(binary == SocketIOFrame.unknown(#"451-["binary"]"#))

        let stranger = SocketIOFrame.decode("9")
        #expect(stranger == SocketIOFrame.unknown("9"))
    }

    @Test("编码：事件带 data 外壳")
    func encoding() {
        #expect(SocketIOFrame.event("stream/detail", data: [:]) == "42[\"stream/detail\",{\"data\":{}}]")
        #expect(
            SocketIOFrame.event("stream/auth", data: ["password": "p1"])
                == "42[\"stream/auth\",{\"data\":{\"password\":\"p1\"}}]"
        )
        #expect(SocketIOFrame.event("stream/input", data: ["command": "list"]) == "42[\"stream/input\",{\"data\":{\"command\":\"list\"}}]")
    }
}
