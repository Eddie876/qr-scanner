import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var cameraService = CameraService()

    var body: some View {
        ZStack {
            // Camera preview (fill entire screen)
            if let previewLayer = cameraService.previewLayer {
                CameraPreview(previewLayer: previewLayer)
                    .ignoresSafeArea()
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

                        // QR scan guide
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

                        Spacer()
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

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func retry() {
        cameraService.retrySetup()
    }
}
