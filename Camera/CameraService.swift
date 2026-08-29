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
    @MainActor @Published private(set) var displayZoom: CGFloat = 1.0
    @MainActor @Published private(set) var telephotoAvailable: Bool = false
    @MainActor private var isOpeningURL = false

    private let sessionQueue = DispatchQueue(label: "qrscanner.capture.session")
    private let debugQueue = DispatchQueue(label: "qrscanner.camera.probe")

    private var captureSession: AVCaptureSession?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var wideCamera: AVCaptureDevice?
    private var telephotoCamera: AVCaptureDevice?
    private var activeDevice: AVCaptureDevice?
    private var activeInput: AVCaptureDeviceInput?

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

    @MainActor
    @objc
    private func appWillEnterForeground() {
        isOpeningURL = false
        sessionQueue.async { [weak self] in
            self?.startScanningOnSessionQueue()
        }
    }

    @MainActor
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

    // MARK: - Zoom Selection

    @MainActor
    func selectOneX() {
        sessionQueue.async { [weak self] in
            self?.selectOneXOnSessionQueue()
        }
    }

    @MainActor
    func selectTwoX() {
        sessionQueue.async { [weak self] in
            self?.selectTwoXOnSessionQueue()
        }
    }

    @MainActor
    func selectTelephoto() {
        sessionQueue.async { [weak self] in
            self?.selectTelephotoOnSessionQueue()
        }
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

        // Discover physical cameras
        let wideDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        let telephotoDevice = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)

        guard let wideDevice else {
            updateStateToFailed("Wide angle camera not available.")
            return
        }

        self.wideCamera = wideDevice
        self.telephotoCamera = telephotoDevice
        self.activeDevice = wideDevice

        // Update telephoto availability on MainActor
        Task { @MainActor in
            self.telephotoAvailable = telephotoDevice != nil
        }

        // Configure device input with wide camera
        do {
            let input = try AVCaptureDeviceInput(device: wideDevice)
            if session.canAddInput(input) {
                session.addInput(input)
                self.activeInput = input
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

        // Configure initial camera
        configureCameraForCapture(wideDevice)

        // Create preview layer
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        updatePreviewLayer(previewLayer)

        self.captureSession = session

        #if DEBUG
        logZoomDebugInfo()
        #endif
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

    // MARK: - Zoom Selection (Phase 2.1)

    private func selectOneXOnSessionQueue() {
        guard let wideCamera, let session = captureSession else { return }

        // If already on wide camera, just adjust zoom
        if activeDevice?.uniqueID == wideCamera.uniqueID {
            setDeviceZoomFactor(wideCamera, factor: 1.0)
        } else {
            // Switch to wide camera
            replaceCameraInput(with: wideCamera)
            setDeviceZoomFactor(wideCamera, factor: 1.0)
        }

        updateDisplayZoom(1.0)
    }

    private func selectTwoXOnSessionQueue() {
        guard let wideCamera, let session = captureSession else { return }

        // Switch to wide camera if not already on it
        if activeDevice?.uniqueID != wideCamera.uniqueID {
            replaceCameraInput(with: wideCamera)
        }

        // Set 2× zoom with clamping
        let zoomFactor = min(2.0, wideCamera.maxAvailableVideoZoomFactor)
        let clampedFactor = max(zoomFactor, wideCamera.minAvailableVideoZoomFactor)
        setDeviceZoomFactor(wideCamera, factor: clampedFactor)

        updateDisplayZoom(clampedFactor)
    }

    private func selectTelephotoOnSessionQueue() {
        guard let telephotoCamera, let session = captureSession else { return }

        // Switch to telephoto camera
        replaceCameraInput(with: telephotoCamera)
        
        // Set telephoto to 1× (native)
        setDeviceZoomFactor(telephotoCamera, factor: 1.0)

        updateDisplayZoom(3.0)
    }

    private func replaceCameraInput(with device: AVCaptureDevice) {
        guard let session = captureSession, let oldInput = activeInput else { return }

        session.beginConfiguration()

        // Remove old input
        session.removeInput(oldInput)

        // Create and add new input
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                self.activeInput = newInput
                self.activeDevice = device
                
                // Configure the new camera
                configureCameraForCapture(device)
                
                session.commitConfiguration()

                #if DEBUG
                logZoomDebugInfo()
                #endif
            } else {
                session.commitConfiguration()
                // Attempt to restore old input
                if session.canAddInput(oldInput) {
                    session.addInput(oldInput)
                }
                updateStateToFailed("Cannot add new camera input.")
            }
        } catch {
            session.commitConfiguration()
            // Attempt to restore old input
            if session.canAddInput(oldInput) {
                session.addInput(oldInput)
            }
            updateStateToFailed("Failed to switch camera: \(error.localizedDescription)")
        }
    }

    private func setDeviceZoomFactor(_ device: AVCaptureDevice, factor: CGFloat) {
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
        } catch {
            print("Failed to set zoom factor: \(error)")
        }
    }

    private func configureCameraForCapture(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            
            device.unlockForConfiguration()
        } catch {
            print("Failed to configure camera: \(error)")
        }
    }

    private func updateDisplayZoom(_ zoom: CGFloat) {
        Task { @MainActor in
            self.displayZoom = zoom
        }
    }

    #if DEBUG
    private func logZoomDebugInfo() {
        guard let activeDevice else { return }
        print("Display Zoom: \(displayZoom)x")
        print("Active Device: \(activeDevice.localizedName)")
        print("Device Type: \(activeDevice.deviceType)")
        print("Device Zoom Factor: \(activeDevice.videoZoomFactor)")
    }
    #endif

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
        for metadata in metadataObjects {
            guard let qrObject = metadata as? AVMetadataMachineReadableCodeObject,
                  let stringValue = qrObject.stringValue else {
                continue
            }

            if let url = Self.parseAndValidateURL(stringValue) {
                // Dispatch to MainActor to handle URL opening and guard
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard !self.isOpeningURL else { return }
                    self.isOpeningURL = true
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    nonisolated private static func parseAndValidateURL(_ string: String) -> URL? {
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
