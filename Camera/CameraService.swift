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

    // Zoom state (sessionQueue-owned)
    private let minimumDisplayZoom: CGFloat = 1.0
    private let telephotoOpticalFactor: CGFloat = 3.0
    private let maximumDisplayZoom: CGFloat = 10.0
    private let lensSwitchCooldown: TimeInterval = 0.2
    
    private var currentDisplayZoom: CGFloat = 1.0
    private var lastLensSwitchTime: TimeInterval = 0
    private var lastZoomUpdateTime: TimeInterval = 0
    private let zoomUpdateThrottleInterval: TimeInterval = 1.0 / 60.0  // 60 Hz

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
        setDisplayZoom(1.0)
    }

    @MainActor
    func selectTwoX() {
        setDisplayZoom(2.0)
    }

    @MainActor
    func selectTelephoto() {
        setDisplayZoom(3.0)
    }

    @MainActor
    func setDisplayZoom(_ zoom: CGFloat) {
        let clampedZoom = max(minimumDisplayZoom, min(zoom, maximumDisplayZoom))
        sessionQueue.async { [weak self] in
            self?.setDisplayZoomOnSessionQueue(clampedZoom)
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

    // MARK: - Zoom Mapping (Phase 2.2)

    private func setDisplayZoomOnSessionQueue(_ targetDisplayZoom: CGFloat) {
        // Throttle zoom updates to ~60 Hz
        let now = CACurrentMediaTime()
        if now - lastZoomUpdateTime < zoomUpdateThrottleInterval {
            return
        }
        lastZoomUpdateTime = now

        guard let session = captureSession, let wide = wideCamera else { return }

        currentDisplayZoom = targetDisplayZoom

        if targetDisplayZoom < telephotoOpticalFactor {
            // Use physical Wide camera
            let shouldSwitchToWide = activeDevice?.uniqueID != wide.uniqueID
            
            if shouldSwitchToWide {
                // Check cooldown before switching
                if now - lastLensSwitchTime >= lensSwitchCooldown {
                    replaceCameraInput(with: wide)
                    lastLensSwitchTime = now
                    #if DEBUG
                    logLensSwitchInfo("Wide")
                    #endif
                }
            }

            // Apply zoom on Wide camera
            let clampedZoom = max(wide.minAvailableVideoZoomFactor, min(targetDisplayZoom, wide.maxAvailableVideoZoomFactor))
            setDeviceZoomFactor(wide, factor: clampedZoom)
        } else {
            // Use physical Telephoto camera
            guard let tele = telephotoCamera else { return }
            
            let shouldSwitchToTele = activeDevice?.uniqueID != tele.uniqueID
            
            if shouldSwitchToTele {
                // Check cooldown before switching
                if now - lastLensSwitchTime >= lensSwitchCooldown {
                    replaceCameraInput(with: tele)
                    lastLensSwitchTime = now
                    #if DEBUG
                    logLensSwitchInfo("Telephoto")
                    #endif
                }
            }

            // Calculate device zoom for telephoto
            let deviceZoom = targetDisplayZoom / telephotoOpticalFactor
            let clampedZoom = max(tele.minAvailableVideoZoomFactor, min(deviceZoom, tele.maxAvailableVideoZoomFactor))
            setDeviceZoomFactor(tele, factor: clampedZoom)
        }

        updateDisplayZoom(targetDisplayZoom)
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
    private func logLensSwitchInfo(_ lensName: String) {
        guard let activeDevice else { return }
        print("Lens switched:")
        print("Display Zoom: \(String(format: "%.2f", currentDisplayZoom))x")
        print("Active Device: \(activeDevice.localizedName)")
        print("Device Type: \(activeDevice.deviceType)")
        print("Device Zoom Factor: \(String(format: "%.4f", activeDevice.videoZoomFactor))")
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
