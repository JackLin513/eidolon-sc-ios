import EidolonCore
import UIKit

/// Draws the outfit thumbnails once (spec「通话层」): the same renderer the call uses, off
/// screen and in `full` framing, snapshotted into `Caches` under her outfit number and the
/// installed bundle's version, and kept in memory for the rest of the process. One renderer
/// is reused and requests are served one at a time, so a grid of cards never opens a WebGL
/// context per card. A thumbnail that cannot be drawn returns nil and the card keeps its
/// placeholder; the next request gets a fresh context. A card scrolled away cancels its
/// wait, so a slow load does not hold the next card for the whole timeout.
@MainActor
final class OutfitThumbnailStore {
    static let shared = OutfitThumbnailStore()

    /// The 4:5 box the cards show. At the screen's scale this is a sharp small picture
    /// without holding a full-size renderer per outfit.
    static let size = CGSize(width: 200, height: 250)

    /// Where the off-screen renderer draws. The picker puts it in the window (behind the
    /// sheet and effectively invisible), because WebKit only paints a view that is on
    /// screen.
    let bench = UIView()

    private let directory: URL
    private let memory = NSCache<NSString, UIImage>()
    private var worker: StandWebRenderer?
    private var workerRoot: URL?

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("StandOutfits", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bench.frame = CGRect(origin: .zero, size: Self.size)
        bench.clipsToBounds = true
        bench.isUserInteractionEnabled = false
    }

    /// The cached thumbnail of an outfit, drawing it if this bundle's version has not been
    /// drawn yet. Requests are serialized: the next outfit is loaded only after the previous
    /// picture is taken, so there is never more than one off-screen renderer.
    func thumbnail(
        for outfit: StandOutfit,
        contentRoot: URL,
        contentVersion: String
    ) async -> UIImage? {
        let key = key(outfit, contentVersion: contentVersion)
        if let cached = cached(key, outfit: outfit, contentVersion: contentVersion) {
            return cached
        }
        await lock()
        defer { unlock() }
        // The lock may have been waited on after the card scrolled away: then nothing is
        // drawn and nothing is cached (the card's `.task` cancels when it leaves).
        guard !Task.isCancelled else { return nil }
        if let cached = cached(key, outfit: outfit, contentVersion: contentVersion) {
            return cached
        }
        guard await waitForBench() else { return nil }
        guard let image = await draw(outfit, contentRoot: contentRoot) else { return nil }
        guard !Task.isCancelled else { return nil }
        memory.setObject(image, forKey: key)
        if let data = image.pngData() {
            try? data.write(to: file(outfit, contentVersion: contentVersion), options: .atomic)
        }
        return image
    }

    /// Stop drawing while the app is not in the foreground.
    func setPaused(_ paused: Bool) {
        worker?.setPaused(paused)
    }

    // MARK: - Drawing

    private func draw(_ outfit: StandOutfit, contentRoot: URL) async -> UIImage? {
        let renderer = renderer(for: contentRoot)
        renderer.setPaused(false)
        // Any early exit below, cancellation included, leaves the off-screen renderer
        // paused instead of drawing for a card that is gone.
        defer { renderer.setPaused(true) }
        renderer.setViewportSize(Self.size)
        renderer.direct(.calm)
        guard await load(outfit, into: renderer) else {
            // A page or outfit that failed never draws again; the next thumbnail starts
            // from a fresh context.
            discardWorker()
            return nil
        }
        guard !Task.isCancelled else { return nil }
        // The camera is sent after the load report and the first frame lands on the next
        // display link: give them a moment before taking the picture. A cancelled sleep
        // means the card went away: take no picture at all.
        do {
            try await Task.sleep(for: .milliseconds(400))
        } catch {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        renderer.setPaused(true)
        guard let image = await renderer.snapshot() else {
            discardWorker()
            return nil
        }
        guard !Task.isCancelled else { return nil }
        return image
    }

    /// Load one outfit and wait for the page's report, or until it gives up. The wait ends
    /// at once if the card goes away, so a slow load cannot hold the next card.
    private func load(_ outfit: StandOutfit, into renderer: StandWebRenderer) async -> Bool {
        let waiter = LoadWaiter()
        renderer.onLoaded = { _ in waiter.finish(true) }
        renderer.onFailure = { _ in waiter.finish(false) }
        renderer.load(outfit)
        return await waiter.wait(timeout: .seconds(15))
    }

    private func renderer(for contentRoot: URL) -> StandWebRenderer {
        if let worker, workerRoot == contentRoot { return worker }
        discardWorker()
        let renderer = StandWebRenderer(contentRoot: contentRoot, framing: .full)
        renderer.view.frame = CGRect(origin: .zero, size: Self.size)
        bench.addSubview(renderer.view)
        worker = renderer
        workerRoot = contentRoot
        return renderer
    }

    private func discardWorker() {
        worker?.setPaused(true)
        worker?.view.removeFromSuperview()
        worker = nil
        workerRoot = nil
    }

    /// The bench has to be in a window for WebKit to paint; the picker's view is laid out
    /// a moment after the first thumbnail is asked for. False when the card went away
    /// while waiting, so the wait ends there instead of drawing for nobody.
    private func waitForBench() async -> Bool {
        for _ in 0..<40 where bench.window == nil {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    // MARK: - The cache

    private func key(_ outfit: StandOutfit, contentVersion: String) -> NSString {
        OutfitThumbnailKey.fileName(outfitID: outfit.id, contentVersion: contentVersion) as NSString
    }

    private func cached(
        _ key: NSString,
        outfit: StandOutfit,
        contentVersion: String
    ) -> UIImage? {
        if let image = memory.object(forKey: key) { return image }
        guard let data = try? Data(contentsOf: file(outfit, contentVersion: contentVersion)),
              let image = UIImage(data: data)
        else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    private func file(_ outfit: StandOutfit, contentVersion: String) -> URL {
        directory.appendingPathComponent(
            OutfitThumbnailKey.fileName(outfitID: outfit.id, contentVersion: contentVersion)
        )
    }

    // MARK: - One at a time

    private func lock() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func unlock() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
