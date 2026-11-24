import AVFoundation
import MeowverseCore
import OSLog
import Photos
import SwiftUI
import UIKit

/// The system camera for "拍照", and what happens to a photo taken with it.
///
/// The picture goes into the same single-photo review as a photo picked from the library.
/// Its bytes are encoded by `CameraCapture`, which keeps the camera's EXIF (capture day and
/// orientation) and drops any location. With "拍的照片也存进“照片”" on, the same bytes are
/// saved to the photo library first, with add-only access, and the new asset's identifier
/// is recorded like a picked photo's.
enum InAppCamera {
    /// Settings switch, on by default: a photo that lives only in the app is lost with the app.
    static let savesToPhotosKey = "camera.savesToPhotos"

    #if DEBUG || DRILLS
    private static let launch = LaunchOptions.current
    #endif

    /// False on the simulator and when Screen Time turns the camera off. Debug and drill
    /// builds can stand a drawn photo in for it (`-MeowverseFakeCamera`).
    static var isAvailable: Bool {
        #if DEBUG || DRILLS
        if launch.fakeCamera { return true }
        #endif
        return UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// Camera access was refused or is restricted. Not asked yet counts as allowed: the system
    /// asks when the camera opens.
    static var isDenied: Bool {
        #if DEBUG || DRILLS
        if launch.fakeCamera { return launch.fakeCameraDenied }
        #endif
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    #if DEBUG || DRILLS
    static var usesFakeCamera: Bool { launch.fakeCamera }
    #endif

    /// What the camera handed over after "使用照片".
    nonisolated struct Shot: @unchecked Sendable {
        let image: UIImage
        let metadata: [String: Any]?
    }

    nonisolated static func encode(_ shot: Shot) throws -> Data {
        guard let cgImage = shot.image.cgImage else { throw IngestError.notAnImage }
        return try CameraCapture.encode(cgImage, orientation: exifOrientation(shot.image.imageOrientation),
                                        metadata: shot.metadata).data
    }

    nonisolated static func exifOrientation(_ orientation: UIImage.Orientation) -> Int {
        switch orientation {
        case .up: 1
        case .upMirrored: 2
        case .down: 3
        case .downMirrored: 4
        case .leftMirrored: 5
        case .right: 6
        case .rightMirrored: 7
        case .left: 8
        @unknown default: 1
        }
    }

    /// Never `.notWanted`: that is the switch being off, when this is not called.
    typealias LibrarySave = CameraCapture.LibrarySave

    /// Adds the bytes as a new photo, asking for add-only access the first time.
    nonisolated static func saveToPhotos(_ data: Data) async -> LibrarySave {
        #if DEBUG || DRILLS
        // UI tests: Photos refuses (no access) or fails (as when storage is full), without being asked.
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-MeowversePhotosSave"), args.indices.contains(index + 1) {
            if args[index + 1] == "refused" { return .refused }
            if args[index + 1] == "failed" { return .failed }
        }
        #endif
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard status == .authorized || status == .limited else {
            log.notice("camera photo not saved to Photos: no add access")
            return .refused
        }
        let created = CreatedAsset()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                created.identifier = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            log.error("camera photo not saved to Photos: \(String(describing: type(of: error)), privacy: .public)")
            return .failed
        }
        // Whether an identifier came back is what device testing needs to see; never the identifier.
        log.notice("camera photo saved to Photos, identifier \(created.identifier == nil ? "missing" : "present", privacy: .public)")
        return .saved(assetIdentifier: created.identifier)
    }

    private nonisolated static let log = Logger(subsystem: "app.meowverse", category: "camera")

    /// Written inside the change block, read after it has finished.
    private nonisolated final class CreatedAsset: @unchecked Sendable {
        var identifier: String?
    }
}

/// Opens the camera full screen, or explains that access is off.
struct CameraScreen: View {
    let onShot: (InAppCamera.Shot) -> Void
    let onCancel: () -> Void

    var body: some View {
        #if DEBUG || DRILLS
        if InAppCamera.usesFakeCamera {
            FakeCameraView(onShot: onShot, onCancel: onCancel)
        } else {
            SystemCamera(onShot: onShot, onCancel: onCancel).ignoresSafeArea()
        }
        #else
        SystemCamera(onShot: onShot, onCancel: onCancel).ignoresSafeArea()
        #endif
    }
}

/// `UIImagePickerController` with its own retake / use photo screen; no custom camera.
private struct SystemCamera: UIViewControllerRepresentable {
    let onShot: (InAppCamera.Shot) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onShot: onShot, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onShot: (InAppCamera.Shot) -> Void
        let onCancel: () -> Void

        init(onShot: @escaping (InAppCamera.Shot) -> Void, onCancel: @escaping () -> Void) {
            self.onShot = onShot
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { onCancel(); return }
            onShot(InAppCamera.Shot(image: image, metadata: info[.mediaMetadata] as? [String: Any]))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
    }
}

#if DEBUG || DRILLS
/// Stands in for the camera on the simulator: "Use Photo" hands over a drawn picture the way
/// the camera does, as sensor-oriented pixels plus a metadata dictionary. The metadata has a
/// capture time and a location, so a test can see the first kept and the second dropped.
private struct FakeCameraView: View {
    let onShot: (InAppCamera.Shot) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text(verbatim: "Drill camera").font(.headline)
            Button { onShot(Self.shot()) } label: { Text(verbatim: "Use Photo") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("fake-camera-use")
            Button(role: .cancel, action: onCancel) { Text(verbatim: "Cancel") }
                .accessibilityIdentifier("fake-camera-cancel")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85).ignoresSafeArea())
        .foregroundStyle(.white)
    }

    /// The synthetic photo's pixels turned a quarter, as a phone held upright records them.
    static func shot() -> InAppCamera.Shot {
        let data = SyntheticPhoto.jpeg(variant: 40)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let upright = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let sensor = rotatedCounterClockwise(upright) else {
            return InAppCamera.Shot(image: UIImage(data: data) ?? UIImage(), metadata: nil)
        }
        let metadata: [String: Any] = [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2026:05:20 16:42:10",
                                                       kCGImagePropertyExifDateTimeDigitized as String: "2026:05:20 16:42:10"],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFOrientation as String: 6],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 1.0,
                                                      kCGImagePropertyGPSLatitudeRef as String: "N"],
        ]
        return InAppCamera.Shot(image: UIImage(cgImage: sensor, scale: 1, orientation: .right), metadata: metadata)
    }

    private static func rotatedCounterClockwise(_ image: CGImage) -> CGImage? {
        let width = image.height, height = image.width
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // y points up here: a quarter turn anticlockwise takes the top edge to the left.
        context.translateBy(x: CGFloat(width), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
#endif
