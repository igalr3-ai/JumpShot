import Foundation

/// UserDefaults keys shared by the camera and the Settings screen (@AppStorage).
enum Key {
    static let front = "front"
    static let zoom = "zoom"            // 0…1 between widest and max zoom
    static let exposure = "exposure"    // EV, −2…+2
    static let fullRes = "fullRes"
    static let shots = "shots"
    static let fps = "fps"              // burst speed, shots per second
    static let sensitivity = "sensitivity" // 0…100
    static let pushOff = "pushOff"
    static let cooldown = "cooldown"    // seconds
    static let armed = "armed"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            front: false, zoom: 0.0, exposure: 0.0, fullRes: false,
            shots: 10, fps: 10.0, sensitivity: 50.0, pushOff: true, cooldown: 2.0, armed: true,
        ])
    }
}
