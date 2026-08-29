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
                ZStack {
                    CameraPreview(previewLayer: previewLayer)
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { gesture in
                                    if !isZoomDragging {
                                        dragStartZoom = cameraService.displayZoom
                                        isZoomDragging = true
                                    }
                                    handleDragZoomChanged(gesture)
                                }
                                .onEnded { _ in
                                    isZoomDragging = false
                                }
                        )
                        .allowsHitTesting(cameraService.selectionCandidates.isEmpty)
                    
                    // Multi-QR selection overlay (Phase B)
                    if cameraService.selectionCandidates.count >= 2 {
                        ForEach(cameraService.selectionCandidates) { candidate in
                            SelectableQRBox(
                                bounds: candidate.bounds,
                                onTap: {
                                    cameraService.selectCandidate(candidate.url)
                                }
                            )
                        }
                    }
                }
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
                    // Scanning state: show QR guide overlay (hide when selecting)
                    if cameraService.selectionCandidates.isEmpty {
                        VStack {
                            Spacer()

                            // QR aiming frame with zoom badge overlay
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.yellow, lineWidth: 2)
                                    .frame(width: 200, height: 200)
                                    .allowsHitTesting(false)

                                // Zoom badge positioned above aiming frame
                                Text(String(format: "%.1f×", cameraService.displayZoom))
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(.yellow)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(Capsule())
                                    .allowsHitTesting(false)
                                    .offset(y: -130)
                                    .opacity(isZoomDragging ? 1 : 0)
                            }

                            Spacer()

                            // Zoom controls at bottom, centered with compact layout
                            HStack(spacing: 26) {
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
                            .padding(.bottom, 6)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Selection mode: show compact rescan button
                        VStack {
                            Spacer()
                            
                            Button(action: { cameraService.cancelSelection() }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(Color.gray.opacity(0.55))
                                    .clipShape(Circle())
                            }
                            .accessibilityLabel("Scan again")
                            .padding(.bottom, 16)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }


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
                .font(.system(size: 17, weight: .medium).monospacedDigit())
                .frame(width: 64, height: 44)
                .foregroundStyle(isSelected ? Color.black.opacity(0.9) : Color.white.opacity(0.9))
                .background(isSelected ? Color.yellow.opacity(0.6) : Color.black.opacity(0.45))
                .clipShape(Capsule())
        }
    }
}

struct SelectableQRBox: View {
    let bounds: CGRect
    let onTap: () -> Void
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.yellow, lineWidth: 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.yellow.opacity(0.15))
                )
                .frame(
                    width: bounds.width,
                    height: bounds.height
                )
        }
        .frame(
            width: bounds.width + 24,
            height: bounds.height + 24
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .position(
            x: bounds.midX,
            y: bounds.midY
        )
    }
}
