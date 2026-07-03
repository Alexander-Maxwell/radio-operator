import SwiftUI

/// Tactical palette, keyed off the Radio Operator emblem: black field, weathered
/// khaki/brass, bone, and the transceiver's amber LCD. Red stays reserved for a
/// live microphone.
enum Palette {
    /// Weathered brass — the "RADIO OPERATOR" lettering, lightning, towers.
    static let accent = Color(red: 0.706, green: 0.639, blue: 0.455)   // #B4A374
    /// Skull bone — bright detail on dark.
    static let bone = Color(red: 0.812, green: 0.780, blue: 0.694)     // #CFC7B2
    /// Transceiver LCD amber — "on air / signal present".
    static let lcd = Color(red: 0.792, green: 0.635, blue: 0.290)      // #CAA24A
    /// Live microphone — recording/transmit.
    static let live = Color(red: 0.710, green: 0.251, blue: 0.220)     // #B54038
    /// OD green — the hold-to-dictate mic-level signal (the pill you see while speaking).
    static let od = Color(red: 0.435, green: 0.514, blue: 0.267)       // #6F8344
}
