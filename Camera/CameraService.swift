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
        print("\n================ Camera Capability Probe (Phase 0) ================")
        print("Rear device count: \(devices.count)")

        if devices.isEmpty {
            print("No rear video devices found.")
            print("===================================================================\n")
            return
        }

        for (index, device) in devices.enumerated() {
            print("\n[Rear Device #\(index + 1)]")
            print("localizedName: \(device.localizedName)")
            print("uniqueID: \(device.uniqueID)")
            print("deviceType: \(device.deviceType)")
            print("isVirtualDevice: \(device.isVirtualDevice)")
            print("constituentDevices: \(device.constituentDevices)")
            print("virtualDeviceSwitchOverVideoZoomFactors: \(device.virtualDeviceSwitchOverVideoZoomFactors)")
            print("minAvailableVideoZoomFactor: \(device.minAvailableVideoZoomFactor)")
            print("maxAvailableVideoZoomFactor: \(device.maxAvailableVideoZoomFactor)")
            print("activeFormat.videoFieldOfView: \(device.activeFormatVideoFieldOfView)")
        }

        print("===================================================================\n")
    }
}
