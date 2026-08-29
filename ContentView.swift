import SwiftUI

struct ContentView: View {
    @StateObject private var cameraService = CameraService()

    var body: some View {
        VStack(spacing: 16) {
            Text("QR Scanner")
                .font(.title2)
                .bold()

            Text("Phase 0: Camera Capability Probe")
                .font(.headline)

            statusView

            Button("Run Probe") {
                cameraService.startPhase0Probe()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .task {
            cameraService.startPhase0Probe()
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch cameraService.state {
        case .idle:
            Text("Idle")
                .foregroundStyle(.secondary)
        case .requestingPermission:
            Text("Requesting camera permission...")
                .foregroundStyle(.secondary)
        case .authorized:
            Text("Authorized. Diagnostics printed to Xcode console.")
                .foregroundStyle(.green)
        case .unauthorized:
            Text("Camera access denied or restricted.")
                .foregroundStyle(.red)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
        }
    }
}
