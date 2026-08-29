import AVFoundation
import Foundation
import UIKit

final class CameraService: NSObject, ObservableObject {
    enum CameraState: Equatable {
        case idle
        case requestingPermission
        case authorized
        case scanning
        case unauthorized
        case failed(String)
    }

    @MainActor @Published private(set) var state: CameraState = .idle
    @MainActor @Published private(set) var diagnosticReport: String = ""
    @MainActor @Published private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    private let sessionQueue = DispatchQueue(label: "qrscanner.capture.session")
    private let debugQueue = DispatchQueue(label: "qrscanner.camera.probe")

    private var captureSession: AVCaptureSession?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var isOpeningURL = false

    @MainActor
    override init() {
        super.init()
        setupAppLifecycleObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - App Lifecycle

    @MainActor
    private func setupAppLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc 
    private func appWillEnterForeground() {
        isOpeningURL = false
        if captureSession != nil {
            startScanning()
        }
    }

    @objc 
    private func appDidEnterBackground() {
        stopScanning()
    }

    // MARK: - Public Interface

    @MainActor
    func requestCameraPermissionAndStartScanning() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            state = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.state = .authorized
                        self.setupAndStartScanning()
                    } else {
                        self.state = .unauthorized
                    }
                }
            }

        case .authorized:
            state = .authorized
            setupAndStartScanning()

        case .denied, .restricted:
            state = .unauthorized

        @unknown default:
            state = .failed("Unknown camera authorization status.")
        }
    }

    @MainActor
    func retrySetup() {
        requestCameraPermissionAndStartScanning()
    }

    // MARK: - Scanner Setup

    @MainActor
    private func setupAndStartScanning() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.setupCaptureSessionOnSessionQueue()
            self.startScanningOnSessionQueue()

            #if DEBUG
            self.debugQueue.async {
                self.runDiagnosticProbe()
            }
            #endif
        }
    }

    private func setupCaptureSessionOnSessionQueue() {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        // Get the wide angle camera
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            updateStateToFailed("Wide angle camera not available.")
            return
        }

        // Configure device input
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                updateStateToFailed("Cannot add camera input to session.")
                return
            }
        } catch {
            updateStateToFailed("Failed to configure camera input: \(error.localizedDescription)")
            return
        }

        // Configure metadata output
        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)

            // Configure QR detection
            if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                metadataOutput.metadataObjectTypes = [.qr]
            } else {
                updateStateToFailed("QR code detection not supported.")
                return
            }
        } else {
            updateStateToFailed("Cannot add metadata output to session.")
            return
        }

        self.metadataOutput = metadataOutput

        // Create preview layer
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        updatePreviewLayer(previewLayer)

        self.captureSession = session
    }

    private func updateStateToFailed(_ message: String) {
        Task { @MainActor in
            self.state = .failed(message)
        }
    }

    private func updatePreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer) {
        Task { @MainActor in
            self.previewLayer = previewLayer
        }
    }

    private func updateStateToScanning() {
        Task { @MainActor in
            self.state = .scanning
        }
    }

    private func startScanningOnSessionQueue() {
        guard let session = captureSession, !session.isRunning else { return }
        session.startRunning()
        updateStateToScanning()
    }

    private func stopScanning() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let session = self.captureSession, session.isRunning else { return }
            session.stopRunning()
        }
    }

    // MARK: - Debugging (Phase 0)

    #if DEBUG
    private func runDiagnosticProbe() {
        let discoveredDevices = discoverRearVideoDevices()
        let diagnostics = discoveredDevices.map(CameraDeviceInfo.init(device:))
        printDiagnosticReport(diagnostics)
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

        Task { @MainActor in
            self.diagnosticReport = report
        }

        print(report)
    }
    #endif
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension CameraService: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !isOpeningURL else { return }

        for metadata in metadataObjects {
            guard let qrObject = metadata as? AVMetadataMachineReadableCodeObject,
                  let stringValue = qrObject.stringValue else {
                continue
            }

            if let url = parseAndValidateURL(stringValue) {
                isOpeningURL = true
                UIApplication.shared.open(url)
            }
        }
    }

    nonisolated private func parseAndValidateURL(_ string: String) -> URL? {
        // Check if it's a valid HTTP(S) URL
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        guard let url = URL(string: trimmed) else {
            return nil
        }

        // Only accept http and https schemes
        if let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                return url
            }
        }

        return nil
    }
}
