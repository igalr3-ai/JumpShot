import SwiftUI

struct ContentView: View {
    @StateObject private var cam = CameraModel()
    @AppStorage(Key.armed) private var armed = true
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: cam.session).ignoresSafeArea()
            PoseOverlay(pose: cam.pose, result: cam.result, frameSize: cam.frameSize, mirrored: cam.mirrored)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            if cam.bursting {
                Rectangle().strokeBorder(Color.red, lineWidth: 10).ignoresSafeArea().allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }

            if let err = cam.errorText { errorOverlay(err) }
        }
        .gesture(
            MagnificationGesture()
                .onChanged { cam.pinch(scale: $0) }
                .onEnded { _ in cam.pinchEnded() }
        )
        .sheet(isPresented: $showSettings, onDismiss: { cam.reloadSettings() }) {
            SettingsView()
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            cam.start()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { cam.start(); cam.refreshThumbnail() }
            if phase == .background { cam.stop() }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cam.status).font(.title2.bold())
            Text(cam.info).font(.caption.monospacedDigit()).foregroundColor(.white.opacity(0.8))
            if !cam.lastBurst.isEmpty {
                Text(cam.lastBurst).font(.caption).foregroundColor(Color(red: 0.61, green: 0.8, blue: 0.4))
            }
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            // Latest photo → Photos app
            Button { PhotoLibrary.openPhotosApp() } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.15))
                    if let img = cam.thumbnail {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle").font(.title3).foregroundColor(.white)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white, lineWidth: 2))
            }
            .accessibilityLabel("Open photos")

            Spacer()

            // Auto-trigger on/off
            Button {
                armed.toggle()
                cam.setArmed(armed)
            } label: {
                ZStack {
                    Circle().fill(armed ? Color(red: 0.9, green: 0.22, blue: 0.21) : Color.gray)
                    JumpFigure(crossed: !armed).fill(Color.white).frame(width: 30, height: 35)
                }
                .frame(width: 56, height: 56)
            }
            .accessibilityLabel(armed ? "Auto-trigger on" : "Auto-trigger off")

            // Manual burst
            Button { cam.fireBurst() } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 5).frame(width: 76, height: 76)
                    Circle().fill(cam.bursting ? Color.red : Color.white)
                        .frame(width: cam.bursting ? 48 : 58, height: cam.bursting ? 48 : 58)
                }
            }
            .padding(.leading, 24)
            .accessibilityLabel("Shoot burst")

            Spacer()

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 26)).foregroundColor(.white)
                    .frame(width: 52, height: 52)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func errorOverlay(_ text: String) -> some View {
        VStack(spacing: 16) {
            Text(text).multilineTextAlignment(.center).foregroundColor(.white)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85).ignoresSafeArea())
    }
}
