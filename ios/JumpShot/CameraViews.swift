import AVFoundation
import SwiftUI

/// Live camera preview (AVCaptureVideoPreviewLayer, aspect-fill).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Skeleton plus stance / dip / airborne lines over the preview, using the same aspect-fill mapping.
struct PoseOverlay: View {
    let pose: Pose
    let result: JumpDetector.Result
    let frameSize: CGSize
    let mirrored: Bool

    private static let bones: [(Joint, Joint)] = [
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist), (.leftShoulder, .leftHip),
        (.rightShoulder, .rightHip), (.leftHip, .rightHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    var body: some View {
        Canvas { ctx, size in
            guard frameSize.width > 0, frameSize.height > 0, !pose.isEmpty else { return }
            let sc = max(size.width / frameSize.width, size.height / frameSize.height)
            let dx = (size.width - frameSize.width * sc) / 2
            let dy = (size.height - frameSize.height * sc) / 2
            func map(_ p: CGPoint) -> CGPoint {
                let x = p.x * sc + dx
                return CGPoint(x: mirrored ? size.width - x : x, y: p.y * sc + dy)
            }
            func y(_ v: CGFloat) -> CGFloat { v * sc + dy }

            var bones = Path()
            for (a, b) in Self.bones {
                if let p = pose[a], let q = pose[b] { bones.move(to: map(p)); bones.addLine(to: map(q)) }
            }
            ctx.stroke(bones, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 3, lineCap: .round))

            func line(_ v: CGFloat?, _ color: Color, dash: [CGFloat], label: String, below: Bool = false) {
                guard let v else { return }
                var p = Path(); p.move(to: CGPoint(x: 0, y: y(v))); p.addLine(to: CGPoint(x: size.width, y: y(v)))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: dash))
                ctx.draw(Text(label).font(.caption).foregroundColor(.white),
                         at: CGPoint(x: 12, y: y(v) + (below ? 12 : -12)), anchor: .leading)
            }
            line(result.baselineY, .green, dash: [], label: "stance")
            line(result.riseLineY, .yellow, dash: [12, 8], label: "airborne")
            line(result.dipLineY, .cyan, dash: [6, 6], label: "dip", below: true)

            if let hip = result.hip {
                let c = map(hip)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)), with: .color(.purple))
            }
        }
    }
}

/// The jumping figure used for the app icon and the auto-trigger button.
struct JumpFigure: Shape {
    var crossed = false

    func path(in r: CGRect) -> Path {
        // Drawn in a 48×56 box, scaled to fit.
        let s = min(r.width / 48, r.height / 56)
        let ox = r.midX - 24 * s, oy = r.midY - 28 * s
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var p = Path()
        p.move(to: P(24, 20)); p.addLine(to: P(24, 38))
        p.move(to: P(24, 24)); p.addLine(to: P(12, 14))
        p.move(to: P(24, 24)); p.addLine(to: P(36, 14))
        p.move(to: P(24, 38)); p.addLine(to: P(14, 44)); p.addLine(to: P(18, 52))
        p.move(to: P(24, 38)); p.addLine(to: P(34, 44)); p.addLine(to: P(30, 52))
        if crossed { p.move(to: P(6, 6)); p.addLine(to: P(42, 50)) }
        p = p.strokedPath(StrokeStyle(lineWidth: 4 * s, lineCap: .round, lineJoin: .round))
        p.addEllipse(in: CGRect(x: ox + 18 * s, y: oy + 6 * s, width: 12 * s, height: 12 * s))
        return p
    }
}
