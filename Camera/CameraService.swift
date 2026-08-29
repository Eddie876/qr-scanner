import AVFoundation
import Foundation

@MainActor
final class CameraService: NSObject, ObservableObject {
    enum CameraState: Equatable {
        case idle
        case requestingPermission
        case authorized
        case unauthorized
        case failed(String)
    }

    @Published private(set) var state: CameraState = .idle
    @Published private(set) var diagnosticReport: String = ""

    private let probeQueue = DispatchQueue(label: "qrscanner.camera.probe")

    func startPhase0Probe() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            state = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                Task { @MainActor in
                    if granted {
                        self.state = .authorized
                        self.discoverAndPrintRearCameraDiagnostics()
                    } else {
                        self.state = .unauthorized
                    }
                }
            }

        case .authorized:
            state = .authorized
            discoverAndPrintRearCameraDiagnostics()

        case .denied, .restricted:
            state = .unauthorized

        @unknown default:
            state = .failed("Unknown camera authorization status.")
        }
    }

    private func discoverAndPrintRearCameraDiagnostics() {
        probeQueue.async {
            let discoveredDevices = self.discoverRearVideoDevices()
            let diagnostics = discoveredDevices.map(CameraDeviceInfo.init(device:))
            self.printDiagnosticReport(diagnostics)
        }
    }

    private func discoverRearVideoDevices() -> [AVCaptureDevice] {
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera
        ]

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredTypes,
            mediaType: .video,
            position: .back
        )

        let allBackVideoDevices = AVCaptureDevice.devices(for: .video)
            .filter { $0.position == .back }

        var byID: [String: AVCaptureDevice] = [:]
        for device in discoverySession.devices {
            byID[device.uniqueID] = device
        }
        for device in allBackVideoDevices {
            byID[device.uniqueID] = device
        }

        return byID.values.sorted { lhs, rhs in
            lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
        }
    }

    private func printDiagnosticReport(_ devices: [CameraDeviceInfo]) {
        var report = ""
        report += "\n================ Camera Capability Probe (Phase 0) ================\n"
        report += "Rear device count: \(devices.count)\n"

        if devices.isEmpty {
            report += "No rear video devices found.\n"
            report += "===================================================================\n"
        } else {
            for (index, device) in devices.enumerated() {
                report += "\n[Rear Device #\(index + 1)]\n"
                report += "localizedName: \(device.localizedName)\n"
                report += "uniqueID: \(device.uniqueID)\n"
                report += "deviceType: \(device.deviceType)\n"
                report += "isVirtualDevice: \(device.isVirtualDevice)\n"
                report += "constituentDevices: \(device.constituentDevices)\n"
                report += "virtualDeviceSwitchOverVideoZoomFactors: \(device.virtualDeviceSwitchOverVideoZoomFactors)\n"
                report += "minAvailableVideoZoomFactor: \(device.minAvailableVideoZoomFactor)\n"
                report += "maxAvailableVideoZoomFactor: \(device.maxAvailableVideoZoomFactor)\n"
                report += "activeFormat.videoFieldOfView: \(device.activeFormatVideoFieldOfView)\n"
            }
            report += "===================================================================\n"
        }

        // Update UI on MainActor
        Task { @MainActor in
            self.diagnosticReport = report
        }

        // Print to console for debugging
        print(report)
    }
}
