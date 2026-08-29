import SwiftUI
import UIKit

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

            HStack(spacing: 12) {
                Button("Run Probe") {
                    cameraService.startPhase0Probe()
                }
                .buttonStyle(.borderedProminent)

                if !cameraService.diagnosticReport.isEmpty {
                    Button(action: copyDiagnostics) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            if !cameraService.diagnosticReport.isEmpty {
                ScrollView {
                    Text(cameraService.diagnosticReport)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .border(Color.gray.opacity(0.3))
                .frame(maxHeight: .infinity)
            } else {
                VStack {
                    Text("No diagnostics available. Tap 'Run Probe' to start.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            }

            Spacer(minLength: 0)
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
            Text("Authorized")
                .foregroundStyle(.green)
        case .unauthorized:
            Text("Camera access denied or restricted.")
                .foregroundStyle(.red)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
        }
    }

    private func copyDiagnostics() {
        UIPasteboard.general.string = cameraService.diagnosticReport
    }
}
