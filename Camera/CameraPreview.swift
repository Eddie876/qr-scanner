import AVFoundation
import SwiftUI
import UIKit

final class CameraPreviewView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()

            if let previewLayer {
                previewLayer.videoGravity = .resizeAspectFill
                layer.addSublayer(previewLayer)
                setNeedsLayout()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.frame = bounds
        CATransaction.commit()
    }
}

struct CameraPreview: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    var onZoomChange: ((CGFloat) -> Void)?

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.backgroundColor = .black
        view.previewLayer = previewLayer
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        if uiView.previewLayer !== previewLayer {
            uiView.previewLayer = previewLayer
        }

        uiView.setNeedsLayout()
    }
}
