import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Key.front) private var front = false
    @AppStorage(Key.zoom) private var zoom = 0.0
    @AppStorage(Key.exposure) private var exposure = 0.0
    @AppStorage(Key.shots) private var shots = 10
    @AppStorage(Key.fps) private var fps = 10.0
    @AppStorage(Key.fullRes) private var fullRes = false
    @AppStorage(Key.sensitivity) private var sensitivity = 50.0
    @AppStorage(Key.pushOff) private var pushOff = true
    @AppStorage(Key.cooldown) private var cooldown = 2.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera") {
                    Toggle("Front camera", isOn: $front)
                    slider("Zoom", value: $zoom, in: 0...1, step: 0.01,
                           text: zoom == 0 ? "widest" : "\(Int(zoom * 100))%",
                           hint: "You can also pinch on the camera preview.")
                    slider("Exposure", value: $exposure, in: -2...2, step: 0.5,
                           text: exposure == 0 ? "0 EV" : String(format: "%+.1f EV", exposure),
                           hint: "Brighten for backlit jumpers, darken against a bright sky.")
                }

                Section("Burst") {
                    Stepper(value: $shots, in: 3...30) {
                        HStack { Text("Shots per jump"); Spacer(); Text("\(shots)").bold().monospacedDigit() }
                    }
                    slider("Burst speed", value: $fps, in: 2...20, step: 1,
                           text: "\(Int(fps)) per second",
                           hint: "How fast shots are requested. The phone may deliver fewer, especially at full resolution.")
                    Toggle("Full resolution", isOn: $fullRes)
                    Text("Off: about 3–12 MP, faster bursts. On: the sensor maximum, slower bursts.")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Section("Jump detection") {
                    slider("Sensitivity", value: $sensitivity, in: 0...100, step: 1,
                           text: "\(Int(sensitivity))",
                           hint: "Higher fires on smaller, slower jumps. Lower if squats or standing up set it off.")
                    Toggle("Fire on push-off", isOn: $pushOff)
                    Text("On: shoots from the explosive phase after the crouch, before the feet leave the ground. Off: waits until the person is clearly in the air.")
                        .font(.footnote).foregroundColor(.secondary)
                    slider("Cooldown after burst", value: $cooldown, in: 0.5...5, step: 0.5,
                           text: String(format: "%.1f s", cooldown),
                           hint: "How long to ignore movement after a jump, so the landing doesn't trigger again.")
                }

                Section("Photos") {
                    Text("Bursts are saved to the \(PhotoLibrary.albumName) album in Photos.")
                    Button("Open Photos") { PhotoLibrary.openPhotosApp() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(.red)
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                        text: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title); Spacer(); Text(text).bold().monospacedDigit() }
            Slider(value: value, in: range, step: step)
            if let hint { Text(hint).font(.footnote).foregroundColor(.secondary) }
        }
        .padding(.vertical, 4)
    }
}
