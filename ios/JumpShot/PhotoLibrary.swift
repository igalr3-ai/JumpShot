import Photos
import UIKit

/// Saves bursts into a "JumpShot" album in Photos and finds the newest one.
enum PhotoLibrary {
    static let albumName = "JumpShot"
    private static var album: PHAssetCollection?

    static var canRead: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    /// Ask for access and make sure the album exists. Calls back on the main queue.
    static func prepare(_ done: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { done(status == .notDetermined) }
                return
            }
            ensureAlbum { DispatchQueue.main.async { done(true) } }
        }
    }

    private static func findAlbum() -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title = %@", albumName)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: opts).firstObject
    }

    private static func ensureAlbum(_ done: @escaping () -> Void) {
        if let a = findAlbum() { album = a; done(); return }
        var placeholder: PHObjectPlaceholder?
        PHPhotoLibrary.shared().performChanges({
            placeholder = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: albumName)
                .placeholderForCreatedAssetCollection
        }) { _, _ in
            if let id = placeholder?.localIdentifier {
                album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
            }
            done()
        }
    }

    /// Save one photo (HEIC or JPEG data) to Photos, inside the JumpShot album when possible.
    static func save(_ data: Data, completion: @escaping (Bool) -> Void) {
        let target = album
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: data, options: nil)
            if let target, let ph = req.placeholderForCreatedAsset,
               let change = PHAssetCollectionChangeRequest(for: target) {
                change.addAssets([ph] as NSArray)
            }
        }) { ok, error in
            if let error { print("JumpShot save failed:", error) }
            completion(ok)
        }
    }

    /// Thumbnail of the newest photo in the album (or the library). Calls back on the main queue.
    static func latestThumbnail(size: CGSize, _ done: @escaping (UIImage?) -> Void) {
        guard canRead else { done(nil); return }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 1
        let assets: PHFetchResult<PHAsset>
        if let a = album ?? findAlbum() {
            assets = PHAsset.fetchAssets(in: a, options: opts)
        } else {
            done(nil); return
        }
        guard let asset = assets.firstObject else { done(nil); return }
        let req = PHImageRequestOptions()
        req.deliveryMode = .opportunistic
        req.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: req) { img, _ in
            DispatchQueue.main.async { done(img) }
        }
    }

    /// Opens the Photos app.
    static func openPhotosApp() {
        if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
    }
}
