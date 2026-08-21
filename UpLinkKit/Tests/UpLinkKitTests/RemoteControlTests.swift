import Testing
import Foundation
@testable import UpLinkKit

@Suite("The doorbell carries commands and nothing else")
struct RemoteControlTests {

    @Test("Every command round-trips")
    func roundTrips() {
        for command in RemoteCommand.allCases {
            #expect(RemoteCommand.decode(command.encoded) == command)
        }
    }

    @Test("A command is exactly one byte")
    func oneByte() {
        for command in RemoteCommand.allCases {
            #expect(command.encoded.count == 1)
        }
    }

    // THE GUARANTEE, AS A TEST. If a longer write were ever accepted this would
    // stop being a control channel and start being a data path — over a radio
    // roughly a hundred times slower than the link it exists to bring up.
    @Test("Anything longer than one byte is refused")
    func refusesPayloads() {
        #expect(RemoteCommand.decode(Data([0x01, 0x01])) == nil)
        #expect(RemoteCommand.decode(Data(repeating: 0x01, count: 512)) == nil)
        #expect(RemoteCommand.decode(Data()) == nil)
    }

    @Test("An unknown byte is refused rather than guessed at")
    func refusesUnknown() {
        #expect(RemoteCommand.decode(Data([0x00])) == nil)
        #expect(RemoteCommand.decode(Data([0xFF])) == nil)
    }

    @Test("The identifiers are distinct, or the phone writes to the wrong one")
    func identifiersAreDistinct() {
        let all = [
            RemoteControlIDs.serviceUUID,
            RemoteControlIDs.commandUUID,
            RemoteControlIDs.stateUUID,
        ]
        #expect(Set(all).count == all.count)
    }
}
