import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var cameraService = CameraService()
    @State private var dragStartZoom: CGFloat = 1.0
    @State private var isZoomDragging = false

    var body: some View {
        ZStack {
            // Camera preview (fill entire screen)
            if let previewLayer = cameraService.previewLayer {
                CameraPreview(previewLayer: previewLayer)
                    .ignoresSafeArea()
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { gesture in
                                if !isZoomDragging {
                                    // Gesture just started
                                    dragStartZoom = cameraService.displayZoom
                                    isZoomDragging = true
                                }
                                handleDragZoomChanged(gesture)
                            }
                            .onEnded { _ in
                                isZoomDragging = false
                            }
                    )
            } else if cameraService.state == .scanning {
                // Placeholder while preview layer is being set up
                Color.black
                    .ignoresSafeArea()
            }

            // Overlay content based on state
            VStack {
                switch cameraService.state {
                case .idle, .requestingPermission:
                    VStack {
                        Spacer()
                        ProgressView()
                            .tint(.white)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.3))

                case .authorized, .scanning:
                    // Scanning state: show QR guide overlay
                    VStack {
                        Spacer()

                        // QR scan guide (visual-only, passthrough to drag gesture)
                        VStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.yellow, lineWidth: 2)
                                .frame(width: 200, height: 200)

                            Text("Point camera at QR code")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        }
                        .padding()
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(12)
                        .allowsHitTesting(false)

                        Spacer()

                        // Zoom badge (temporary, appears during drag)
                        if isZoomDragging {
                            Text(String(format: "%.1f×", cameraService.displayZoom))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Capsule())
                                .allowsHitTesting(false)
                        }

                        // Zoom controls at bottom
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                ZoomButton(
                                    label: "1×",
                                    isSelected: cameraService.displayZoom == 1.0,
                                    action: { cameraService.selectOneX() }
                                )

                                ZoomButton(
                                    label: "2×",
                                    isSelected: cameraService.displayZoom == 2.0,
                                    action: { cameraService.selectTwoX() }
                                )

                                if cameraService.telephotoAvailable {
                                    ZoomButton(
                                        label: "3×",
                                        isSelected: cameraService.displayZoom == 3.0,
                                        action: { cameraService.selectTelephoto() }
                                    )
                                }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.bottom)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .unauthorized:
                    // Permission denied
                    VStack(spacing: 20) {
                        Spacer()

                        VStack(spacing: 12) {
                            Image(systemName: "camera.slash")
                                .font(.system(size: 48))
                                .foregroundStyle(.red)

                            Text("Camera Access Required")
                                .font(.headline)
                                .foregroundStyle(.white)

                            Text("This app needs camera access to scan QR codes.")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .padding()

                        Button(action: openSettings) {
                            Text("Open Settings")
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .background(Color.blue)
                                .foregroundStyle(.white)
                                .cornerRadius(8)
                        }
                        .padding()

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.6))

                case .failed(let message):
                    // Error state
                    VStack(spacing: 20) {
                        Spacer()

                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 48))
                                .foregroundStyle(.orange)

                            Text("Camera Error")
                                .font(.headline)
                                .foregroundStyle(.white)

                            Text(message)
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .padding()

                        Button(action: retry) {
                            Text("Retry")
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .background(Color.blue)
                                .foregroundStyle(.white)
                                .cornerRadius(8)
                        }
                        .padding()

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.6))
                }
            }
        }
        .task {
            cameraService.requestCameraPermissionAndStartScanning()
        }
    }

    private func handleDragZoomChanged(_ gesture: DragGesture.Value) {
        // Calculate target zoom from vertical drag translation
        // Always calculate from the zoom recorded at gesture start
        let zoomPerPoint: CGFloat = 0.02
        let zoomDelta = -gesture.translation.height * zoomPerPoint
        let targetZoom = dragStartZoom + zoomDelta
        cameraService.setDisplayZoom(targetZoom)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func retry() {
        cameraService.retrySetup()
    }
}

struct ZoomButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(isSelected ? Color.blue : Color.black.opacity(0.5))
                .foregroundStyle(.white)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                )
        }
    }
}
