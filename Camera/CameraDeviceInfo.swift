import AVFoundation
import CoreGraphics
import Foundation

struct CameraDeviceInfo {
    let localizedName: String
    let uniqueID: String
    let deviceType: String
    let isVirtualDevice: Bool
    let constituentDevices: [String]
    let virtualDeviceSwitchOverVideoZoomFactors: [CGFloat]
    let minAvailableVideoZoomFactor: CGFloat
    let maxAvailableVideoZoomFactor: CGFloat
    let activeFormatVideoFieldOfView: Float

    init(device: AVCaptureDevice) {
        localizedName = device.localizedName
        uniqueID = device.uniqueID
        deviceType = String(describing: device.deviceType)
        isVirtualDevice = device.isVirtualDevice
        constituentDevices = device.constituentDevices.map {
            "\($0.localizedName) [\(String(describing: $0.deviceType))] id=\($0.uniqueID)"
        }
        virtualDeviceSwitchOverVideoZoomFactors = device.virtualDeviceSwitchOverVideoZoomFactors.map {
            CGFloat(truncating: $0)
        }
        minAvailableVideoZoomFactor = device.minAvailableVideoZoomFactor
        maxAvailableVideoZoomFactor = device.maxAvailableVideoZoomFactor
        activeFormatVideoFieldOfView = device.activeFormat.videoFieldOfView
    }
}
