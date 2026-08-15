import Testing
import Foundation
@testable import UpLinkKit

// The usbmux codec is the only part of the wired transport that sees raw bytes
// from a daemon we do not control, and it is the layer where a mistake is
// invisible: a wrong byte order or a mis-sized header produces a plausible
// message rather than an obvious crash. Everything here is a pure function, so
// all of it is provable without a cable.

@Suite("usbmux codec")
struct USBMuxProtocolTests {

    @Test("A header survives an encode/decode round trip")
    func headerRoundTrip() {
        let original = USBMuxCodec.Header(length: 320, version: 1, message: 8, tag: 7)
        let decoded = USBMuxCodec.decodeHeader(USBMuxCodec.encodeHeader(original))
        #expect(decoded == original)
    }

    @Test("A header is little-endian on the wire")
    func headerIsLittleEndian() {
        let encoded = USBMuxCodec.encodeHeader(
            USBMuxCodec.Header(length: 16, version: 1, message: 8, tag: 0)
        )
        // 16 == 0x10, low byte first. A big-endian encoder would put the 0x10
        // in the fourth byte and usbmuxd would read a 268435456-byte message.
        #expect(Array(encoded.prefix(8)) == [0x10, 0, 0, 0, 0x01, 0, 0, 0])
    }

    @Test("Fewer than sixteen bytes is not yet a header")
    func shortHeaderYieldsNothing() {
        let encoded = USBMuxCodec.encodeHeader(
            USBMuxCodec.Header(length: 16, version: 1, message: 8, tag: 0)
        )
        #expect(USBMuxCodec.decodeHeader(encoded.dropLast()) == nil)
    }

    // The single easiest thing to get wrong in this protocol. `PortNumber` is
    // an ordinary-looking plist integer that usbmuxd reads as big-endian, so an
    // unswapped 50505 asks for port 18885 and comes back "connection refused"
    // — an error that points at the phone rather than at this line.
    @Test("PortNumber is byte-swapped, and swapping twice is the identity")
    func portNumberIsByteSwapped() {
        #expect(USBMuxCodec.wirePort(50505) == 0x49C5)
        #expect(USBMuxCodec.hostPort(0x49C5) == 50505)

        for port: UInt16 in [1, 22, 80, 1080, 50505, 50506, 65535] {
            #expect(USBMuxCodec.hostPort(USBMuxCodec.wirePort(port)) == port)
        }
    }

    @Test("A Connect request carries the device, the swapped port, and the required client keys")
    func connectRequestBody() throws {
        let encoded = try USBMuxCodec.encode(.connect(deviceID: 12, port: 50505), tag: 3)
        let header = try #require(USBMuxCodec.decodeHeader(encoded))

        #expect(header.length == UInt32(encoded.count))
        #expect(header.version == 1)
        #expect(header.message == 8)
        #expect(header.tag == 3)

        let body = encoded.dropFirst(USBMuxCodec.headerSize)
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: body, options: [], format: nil
        ) as? [String: Any])

        #expect(plist["MessageType"] as? String == "Connect")
        #expect(plist["DeviceID"] as? Int == 12)
        #expect(plist["PortNumber"] as? Int == 0x49C5)
        // usbmuxd rejects a request that omits either of these.
        #expect(plist["ClientVersionString"] as? String != nil)
        #expect(plist["ProgName"] as? String != nil)
    }

    @Test("A Result decodes to its code")
    func decodesResult() throws {
        let decoded = try USBMuxCodec.decode(Self.frame([
            "MessageType": "Result", "Number": 3,
        ]))
        let (reply, consumed) = try #require(decoded)
        #expect(reply == .result(.connectionRefused))
        #expect(consumed > USBMuxCodec.headerSize)
    }

    @Test("An Attached message decodes to a device with its UDID and connection type")
    func decodesAttached() throws {
        let decoded = try USBMuxCodec.decode(Self.frame([
            "MessageType": "Attached",
            "DeviceID": 4,
            "Properties": ["SerialNumber": "00008120-ABC", "ConnectionType": "USB"],
        ]))
        let (reply, _) = try #require(decoded)
        #expect(reply == .attached(USBDevice(deviceID: 4, udid: "00008120-ABC", connectionType: .usb)))
    }

    @Test("A Wi-Fi-paired device decodes as .network, not as a cable")
    func decodesNetworkConnectionType() throws {
        let decoded = try USBMuxCodec.decode(Self.frame([
            "MessageType": "Attached",
            "DeviceID": 4,
            "Properties": ["SerialNumber": "00008120-ABC", "ConnectionType": "Network"],
        ]))
        let (reply, _) = try #require(decoded)
        guard case let .attached(device) = reply else {
            Issue.record("expected an attach")
            return
        }
        #expect(device.connectionType == .network)
        #expect(device.connectionType.isCable == false)
    }

    @Test("A Detached message decodes to its device id")
    func decodesDetached() throws {
        let decoded = try USBMuxCodec.decode(Self.frame(["MessageType": "Detached", "DeviceID": 9]))
        let (reply, _) = try #require(decoded)
        #expect(reply == .detached(deviceID: 9))
    }

    @Test("An incomplete message yields nothing rather than a partial parse")
    func partialMessageYieldsNothing() throws {
        let whole = Self.frame(["MessageType": "Result", "Number": 0])
        #expect(try USBMuxCodec.decode(whole.dropLast(4)) == nil)
        #expect(try USBMuxCodec.decode(Data()) == nil)
    }

    @Test("Two messages in one buffer decode one at a time")
    func decodesOneMessageAtATime() throws {
        let first = Self.frame(["MessageType": "Result", "Number": 0])
        let second = Self.frame(["MessageType": "Detached", "DeviceID": 2])

        var buffer = first + second
        let (replyA, consumedA) = try #require(try USBMuxCodec.decode(buffer))
        #expect(replyA == .result(.ok))
        #expect(consumedA == first.count)

        buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + consumedA)
        let (replyB, _) = try #require(try USBMuxCodec.decode(buffer))
        #expect(replyB == .detached(deviceID: 2))
    }

    // A length below the header size would underflow into a huge unsigned body
    // length and make the reader wait forever for bytes that are not coming.
    @Test("A header claiming less than sixteen bytes is rejected, not underflowed")
    func rejectsUndersizedLength() {
        var data = USBMuxCodec.encodeHeader(
            USBMuxCodec.Header(length: 4, version: 1, message: 8, tag: 0)
        )
        data.append(Data(repeating: 0, count: 8))
        #expect(throws: USBMuxError.self) { try USBMuxCodec.decode(data) }
    }

    // FOUND BY THE REAL DAEMON, not by this suite — which is the point.
    //
    // `badVersion` was written as 5 from memory. Every test here passed,
    // because the fake daemon was built on the same assumption: both sides
    // agreed on a number Apple does not use. Sending a bad header version to
    // the real usbmuxd returns 6, and the client rejected that as "unknown
    // Result number 6", turning a precise daemon error into a parse failure.
    //
    // `spike/usb-probe --selftest` exists to break that circularity, and needs
    // no device to do it.
    @Test("Result codes match the daemon's, including BADVERSION = 6")
    func resultCodesMatchTheDaemon() throws {
        #expect(USBMuxCodec.ResultCode(rawValue: 0) == .ok)
        #expect(USBMuxCodec.ResultCode(rawValue: 1) == .badCommand)
        #expect(USBMuxCodec.ResultCode(rawValue: 2) == .badDevice)
        #expect(USBMuxCodec.ResultCode(rawValue: 3) == .connectionRefused)
        #expect(USBMuxCodec.ResultCode(rawValue: 6) == .badVersion)
        // 5 is NOT badVersion, whatever the first version of this said.
        #expect(USBMuxCodec.ResultCode(rawValue: 5) == nil)
    }

    // A code this build does not know must survive to be logged. Throwing
    // discarded the one piece of information the daemon was offering, and would
    // do the same for any code a future macOS introduces.
    @Test("An unrecognised result number is carried, not thrown")
    func unknownResultIsCarried() throws {
        let (reply, _) = try #require(try USBMuxCodec.decode(Self.frame([
            "MessageType": "Result", "Number": 42,
        ])))
        #expect(reply == .unknownResult(42))
    }

    @Test("An unknown message type is carried, not thrown — one stray event must not kill the stream")
    func unknownMessageTypeIsCarried() throws {
        let (reply, _) = try #require(try USBMuxCodec.decode(Self.frame([
            "MessageType": "SomethingNewInASoftwareUpdate",
        ])))
        #expect(reply == .unrecognised(messageType: "SomethingNewInASoftwareUpdate"))
    }

    private static func frame(_ plist: [String: Any]) -> Data {
        let body = try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        return USBMuxCodec.encodeHeader(USBMuxCodec.Header(
            length: UInt32(USBMuxCodec.headerSize + body.count),
            version: 1, message: 8, tag: 1
        )) + body
    }
}
