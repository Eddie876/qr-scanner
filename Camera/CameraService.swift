import AVFoundation
import Foundation
import UIKit

struct QRCandidate: Identifiable {
    let url: URL
    let bounds: CGRect
    
    var id: URL { url }
}

final class CameraService: NSObject, ObservableObject {
    enum CameraState: Equatable {
        case idle
        case requestingPermission
        case authorized
        case scanning
        case unauthorized
        case failed(String)
    }

    enum ScanDecisionState: Equatable {
        case scanning
        case initialWaiting
        case stabilizingMultiple
        case selecting
        case waitingForClearAfterCancel
        case opening
    }

    @MainActor @Published private(set) var state: CameraState = .idle
    @MainActor @Published private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    @MainActor @Published private(set) var displayZoom: CGFloat = 1.0
    @MainActor @Published private(set) var telephotoAvailable: Bool = false
    @MainActor @Published private(set) var selectionCandidates: [QRCandidate] = []
    @MainActor private var isOpeningURL = false

    // Scan arbitration (Phase A)
    @MainActor private var scanDecisionState: ScanDecisionState = .scanning
    @MainActor private var pendingCandidates: Set<URL> = []
    @MainActor private var lastObservedCandidates: Set<URL> = []
    @MainActor private var initialWindowTimer: Task<Void, Never>?
    @MainActor private var stabilityWindowTimer: Task<Void, Never>?
    @MainActor private var scanGenerationToken: Int = 0
    
    // Selection state (Phase B)
    @MainActor private var latestCandidatesByURL: [URL: QRCandidate] = [:]

    private let sessionQueue = DispatchQueue(label: "qrscanner.capture.session")

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
        resetScanArbitration()
        sessionQueue.async { [weak self] in
            self?.startScanningOnSessionQueue()
        }
    }

    @MainActor
    @objc
    private func appDidEnterBackground() {
        resetScanArbitration()
        stopScanning()
    }

    @MainActor
    private func resetScanArbitration() {
        initialWindowTimer?.cancel()
        initialWindowTimer = nil
        stabilityWindowTimer?.cancel()
        stabilityWindowTimer = nil
        pendingCandidates.removeAll()
        lastObservedCandidates.removeAll()
        latestCandidatesByURL.removeAll()
        selectionCandidates.removeAll()
        unfreezePreview()
        scanDecisionState = .scanning
        scanGenerationToken += 1
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
        }
    }

    private func setupCaptureSessionOnSessionQueue() {
        // Avoid recreating session if one already exists
        guard captureSession == nil else {
            startScanningOnSessionQueue()
            return
        }

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

    // MARK: - Zoom Mapping and Camera Switching

    private func setDisplayZoomOnSessionQueue(_ targetDisplayZoom: CGFloat) {
        // Throttle zoom updates to ~60 Hz
        let now = CACurrentMediaTime()
        if now - lastZoomUpdateTime < zoomUpdateThrottleInterval {
            return
        }
        lastZoomUpdateTime = now

        guard let wide = wideCamera else { return }

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
            // Use physical Telephoto camera, or fall back to Wide if unavailable
            guard let tele = telephotoCamera else {
                // Telephoto not available, use wide camera at maximum zoom
                let clampedZoom = max(wide.minAvailableVideoZoomFactor, min(targetDisplayZoom, wide.maxAvailableVideoZoomFactor))
                setDeviceZoomFactor(wide, factor: clampedZoom)
                updateDisplayZoom(targetDisplayZoom)
                return
            }
            
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
                // New input cannot be added, restore old input
                if session.canAddInput(oldInput) {
                    session.addInput(oldInput)
                    session.commitConfiguration()
                } else {
                    session.commitConfiguration()
                    updateStateToFailed("Cannot add new camera input and failed to restore old input.")
                }
            }
        } catch {
            // Failed to create new input, restore old input
            if session.canAddInput(oldInput) {
                session.addInput(oldInput)
                session.commitConfiguration()
            } else {
                session.commitConfiguration()
                updateStateToFailed("Failed to switch camera: \(error.localizedDescription)")
            }
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

    // MARK: - Scan Arbitration (Phase A)

    @MainActor
    private func handleScannedURLs(_ urls: Set<URL>, withBounds bounds: [URL: CGRect]) {
        guard !urls.isEmpty || !pendingCandidates.isEmpty else {
            return
        }

        // Update latest candidate positions in all states except .opening
        if scanDecisionState != .opening {
            for url in urls {
                if let bounds = bounds[url] {
                    latestCandidatesByURL[url] = QRCandidate(url: url, bounds: bounds)
                }
            }
        }

        switch scanDecisionState {
        case .scanning:
            if urls.isEmpty {
                return
            }
            // Transition to initial waiting
            pendingCandidates = urls
            lastObservedCandidates = urls
            scanDecisionState = .initialWaiting
            
            #if DEBUG
            print("Initial window started")
            #endif
            
            startInitialWindowTimer()

        case .initialWaiting:
            // Update pending candidates but don't restart the timer
            pendingCandidates = urls

        case .stabilizingMultiple:
            // Check if the URL set changed (fix DEBUG bug by capturing oldSet)
            if urls != lastObservedCandidates {
                let oldSet = lastObservedCandidates
                lastObservedCandidates = urls
                pendingCandidates = urls
                
                #if DEBUG
                let oldStr = oldSet.map { $0.absoluteString }.sorted().joined(separator: ", ")
                let newStr = urls.map { $0.absoluteString }.sorted().joined(separator: ", ")
                print("Multi set changed: [\(oldStr)] -> [\(newStr)]")
                print("→ reset 150 ms stability timer")
                #endif
                
                // Restart stability timer
                stabilityWindowTimer?.cancel()
                startStabilityWindowTimer()
            } else {
                // Set unchanged, but update pending candidates (for bounds updates)
                pendingCandidates = urls
            }

        case .selecting, .opening:
            // Ignore metadata while selecting or opening
            break
            
        case .waitingForClearAfterCancel:
            // Wait until URLs become empty
            if urls.isEmpty {
                #if DEBUG
                print("QR group cleared after cancel")
                print("→ back to scanning")
                #endif
                scanDecisionState = .scanning
                pendingCandidates.removeAll()
                latestCandidatesByURL.removeAll()
            }
        }
    }

    @MainActor
    private func startInitialWindowTimer() {
        let token = scanGenerationToken
        
        initialWindowTimer = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)  // 150 ms
            
            await MainActor.run { [weak self] in
                guard let self, self.scanGenerationToken == token else { return }
                
                let currentURLs = self.pendingCandidates
                
                #if DEBUG
                if currentURLs.isEmpty {
                    print("Initial result: EMPTY")
                } else if currentURLs.count == 1 {
                    print("Initial result: [\(currentURLs.first?.absoluteString ?? "")]")
                    print("→ OPEN single candidate")
                } else {
                    print("Initial result: [\(currentURLs.map { $0.absoluteString }.sorted().joined(separator: ", "))]")
                    print("→ ENTER multi stabilization")
                }
                #endif
                
                switch currentURLs.count {
                case 0:
                    self.scanDecisionState = .scanning
                    self.pendingCandidates.removeAll()
                    
                case 1:
                    if let url = currentURLs.first {
                        self.openURL(url)
                    }
                    
                default:
                    self.scanDecisionState = .stabilizingMultiple
                    self.lastObservedCandidates = currentURLs
                    self.startStabilityWindowTimer()
                }
            }
        }
    }

    @MainActor
    private func startStabilityWindowTimer() {
        let token = scanGenerationToken
        
        stabilityWindowTimer = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)  // 150 ms
            
            await MainActor.run { [weak self] in
                guard let self, self.scanGenerationToken == token else { return }
                
                let currentURLs = self.pendingCandidates
                
                #if DEBUG
                if currentURLs.count >= 2 {
                    print("Stable multi result: [\(currentURLs.map { $0.absoluteString }.sorted().joined(separator: ", "))]")
                    print("→ ENTER SELECTION MODE")
                } else if currentURLs.count == 1 {
                    print("Stable single result: [\(currentURLs.first?.absoluteString ?? "")]")
                    print("→ OPEN single candidate")
                } else {
                    print("Stable empty result")
                    print("→ back to scanning")
                }
                #endif
                
                switch currentURLs.count {
                case 0:
                    self.scanDecisionState = .scanning
                    self.pendingCandidates.removeAll()
                    self.latestCandidatesByURL.removeAll()
                    
                case 1:
                    if let url = currentURLs.first {
                        self.openURL(url)
                    }
                    
                default:
                    // 2+ URLs: enter selection mode (Phase B)
                    self.scanDecisionState = .selecting
                    self.selectionCandidates = currentURLs
                        .compactMap { url in self.latestCandidatesByURL[url] }
                        .sorted { $0.url.absoluteString < $1.url.absoluteString }
                    self.freezePreview()
                }
            }
        }
    }

    @MainActor
    private func openURL(_ url: URL) {
        guard !isOpeningURL else { return }
        
        resetScanArbitration()
        isOpeningURL = true
        scanDecisionState = .opening
        
        UIApplication.shared.open(url)
    }

    @MainActor
    private func freezePreview() {
        previewLayer?.connection?.isEnabled = false
    }

    @MainActor
    private func unfreezePreview() {
        previewLayer?.connection?.isEnabled = true
    }

    @MainActor
    func selectCandidate(_ url: URL) {
        guard !isOpeningURL, scanDecisionState == .selecting else { return }
        openURL(url)
    }

    @MainActor
    func cancelSelection() {
        guard scanDecisionState == .selecting else { return }
        selectionCandidates.removeAll()
        latestCandidatesByURL.removeAll()
        unfreezePreview()
        scanDecisionState = .waitingForClearAfterCancel
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension CameraService: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        MainActor.assumeIsolated { [self] in
            guard let previewLayer else { return }

            var validURLs: Set<URL> = []
            var candidatesWithBounds: [URL: CGRect] = [:]

            for metadata in metadataObjects {
                guard let qrObject = metadata as? AVMetadataMachineReadableCodeObject,
                      let stringValue = qrObject.stringValue else {
                    continue
                }

                if let url = Self.parseAndValidateURL(stringValue) {
                    validURLs.insert(url)

                    if let transformedQR = previewLayer.transformedMetadataObject(for: qrObject) as? AVMetadataMachineReadableCodeObject {
                        candidatesWithBounds[url] = transformedQR.bounds
                    }
                }
            }

            handleScannedURLs(validURLs, withBounds: candidatesWithBounds)
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
