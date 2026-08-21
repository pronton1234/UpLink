import Foundation

/// The doorbell the phone rings to bring the Mac's access point up.
///
/// **This exists because starting cannot happen over the access point itself.**
/// The phone's only path to the Mac is the network the Mac hosts, so a Mac
/// waiting to be asked over that network can never be asked at all. Something
/// that works while the access point is *down* is required, and Bluetooth LE is
/// the only such channel available to both devices: a separate radio, always
/// listening, needing no association.
///
/// **It carries commands and nothing else, by construction.** A command is one
/// byte. There is no length field, no payload, and no framing — so there is no
/// way for traffic to travel this way even by mistake, and no temptation to add
/// one later. Every byte of actual data goes over the 5 GHz link, which is a
/// different radio in a different band from BLE's 2.4 GHz and does not contend
/// with it.
public enum RemoteCommand: UInt8, Sendable, CaseIterable, Equatable {

    /// Bring the access point up.
    case raiseAccessPoint = 0x01
    /// Take it down and give the Mac its own Wi-Fi back.
    case lowerAccessPoint = 0x02

    /// The single byte written to the characteristic.
    public var encoded: Data { Data([rawValue]) }

    /// Decodes a written value, rejecting anything that is not exactly one
    /// known byte.
    ///
    /// Strict on length as well as value: accepting a long write would make
    /// this a data path, which is the one thing it must never become.
    public static func decode(_ data: Data) -> RemoteCommand? {
        guard data.count == 1 else { return nil }
        return RemoteCommand(rawValue: data[data.startIndex])
    }
}

/// Identifiers both sides must agree on.
public enum RemoteControlIDs {
    /// Advertised by the Mac, scanned for by the phone.
    public static let serviceUUID = "8B1F0001-2C4A-4E7B-9F3D-6A5E8C2B1D40"
    /// Written by the phone, one byte at a time.
    public static let commandUUID = "8B1F0002-2C4A-4E7B-9F3D-6A5E8C2B1D40"
    /// Read by the phone to learn whether the access point is already up, so a
    /// redundant raise is never sent.
    public static let stateUUID = "8B1F0003-2C4A-4E7B-9F3D-6A5E8C2B1D40"
}
