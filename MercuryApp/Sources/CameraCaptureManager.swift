import AVFoundation
import Vision
import CoreImage

/// Captures webcam frames. The session can run continuously (to drive a live
/// self-view preview). In cutout mode, Vision produces shared transparent frames
/// for the preview and recording on the capture queue; late frames are discarded.
final class CameraCaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.mercury.camera")

    /// Frame sink — set by the recorder while recording, cleared otherwise.
    var onFrame: ((CVPixelBuffer) -> Void)?

    var onCutoutFrame: ((CGImage) -> Void)?
    private let modeLock = NSLock()
    private var cutoutEnabled = false
    var removeBackground: Bool {
        get { modeLock.lock(); defer { modeLock.unlock() }; return cutoutEnabled }
        set { modeLock.lock(); cutoutEnabled = newValue; modeLock.unlock() }
    }
    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private let imageContext = CIContext()

    private(set) var isRunning = false
    private var currentDeviceID: String?

    static func availableCameras() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    /// Starts (or restarts, if the device changed) the capture session.
    func start(deviceID: String?) throws {
        // Already running the requested device — nothing to do.
        if isRunning && deviceID == currentDeviceID { return }
        if isRunning { stop() }

        let device: AVCaptureDevice?
        if let deviceID, let d = AVCaptureDevice(uniqueID: deviceID) {
            device = d
        } else {
            device = Self.availableCameras().first ?? AVCaptureDevice.default(for: .video)
        }
        guard let device else { throw NSError(domain: "Mercury", code: -10,
            userInfo: [NSLocalizedDescriptionKey: "No camera available."]) }

        session.beginConfiguration()
        session.sessionPreset = .high
        // Remove any prior inputs (device switch).
        for input in session.inputs { session.removeInput(input) }
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }

        if session.outputs.isEmpty {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()

        currentDeviceID = deviceID
        isRunning = true
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        isRunning = false
        currentDeviceID = nil
        onFrame = nil
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard removeBackground else { onFrame?(px); return }
        autoreleasepool {
            do {
                try VNImageRequestHandler(cvPixelBuffer: px, orientation: .up).perform([segmentation])
                guard removeBackground, let maskBuffer = segmentation.results?.first?.pixelBuffer else { return }
                let source = CIImage(cvPixelBuffer: px)
                let mask = CIImage(cvPixelBuffer: maskBuffer)
                let fittedMask = mask.transformed(by: CGAffineTransform(scaleX: source.extent.width / mask.extent.width,
                                                                        y: source.extent.height / mask.extent.height))
                let cutout = source.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: fittedMask
                ]).cropped(to: source.extent)
                let scale = min(1, 960 / source.extent.width)
                let scaled = cutout.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if let image = imageContext.createCGImage(scaled, from: scaled.extent), removeBackground {
                    onCutoutFrame?(image)
                }
            } catch {
                // Keep the last cutout; never reveal the background after opting to remove it.
            }
        }
    }
}
