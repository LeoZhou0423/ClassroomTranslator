import Foundation
import AVFoundation

@MainActor
@Observable
final class AudioManager {
    var inputDevices: [AudioDevice] = []
    var selectedDevice: AudioDevice?
    var inputLevel: Float = 0
    
    struct AudioDevice: Identifiable, Hashable {
        let id: String
        let name: String
        let isBuiltIn: Bool
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
        
        static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
            lhs.id == rhs.id
        }
    }
    
    init() {
        refreshDevices()
    }
    
    func refreshDevices() {
        inputDevices = [
            AudioDevice(id: "default", name: "Default Microphone", isBuiltIn: true)
        ]
    }
}
