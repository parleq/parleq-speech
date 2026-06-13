// LocalModelStore — download, custody, and lifecycle for the on-device
// cleanup model. Parleq-owned directory (NOT the shared HF cache) so
// "Remove downloaded model" accounts for every byte and uninstall is
// clean. Partial files are preserved across app restarts so a download
// interrupted by a crash or force-quit can be resumed on relaunch;
// however, a user-initiated remove() deletes all partial files.
// The ".parleq-ready" marker is written ONLY after every file lands,
// so a killed download never presents as ready.
import Combine
import Foundation
import HuggingFace

@MainActor
public final class LocalModelStore: ObservableObject {
    public enum State: Equatable {
        case notDownloaded
        case downloading(progress: Double)   // 0…1
        case ready
        case failed(message: String)
    }
    @Published public private(set) var state: State {
        didSet { onStateChanged?(state) }
    }

    /// Called on every state transition. main.swift wires this to update the
    /// menu bar's download-progress item (mirroring LocalASR.onReadyChanged).
    /// AppKit callers (MenuBar, main.swift) can't hold a Combine cancellable
    /// without an anchor object; a plain callback avoids that boilerplate.
    /// Always invoked on @MainActor (LocalModelStore is @MainActor).
    public var onStateChanged: ((State) -> Void)?

    public let checkpoint: String
    public let modelDirectory: URL
    private let readyMarker = ".parleq-ready"

    // Retained so remove() can cancel an in-flight download before deleting
    // the directory, preventing the cancelled task from writing .parleq-ready
    // into an already-removed tree.
    private var downloadTask: Task<Void, Never>?

    // Epoch counter incremented by download() and remove(). Each download
    // task captures the epoch at launch; any deferred state writes (from
    // cancellation or error handlers that resume after a later remove()+
    // download() pair) are ignored when the captured epoch no longer matches
    // the current one, preventing a stale .notDownloaded from clobbering a
    // freshly started .downloading state.
    private var downloadEpoch: Int = 0

    // snapshotDirectory == modelDirectory because we download each file
    // directly into modelDirectory (no cache subdirectory). See Option B
    // rationale in performDownload().
    public var snapshotDirectory: URL { modelDirectory }

    // MARK: - nonisolated helpers

    /// Returns true iff the on-disk ready-marker exists for `checkpoint` under
    /// `root`, WITHOUT touching any @MainActor state.
    ///
    /// This is the single canonical path-construction logic for both
    /// `isReadyOnDisk` and `init`. It replaces "/" with "--" to mirror
    /// Python's `huggingface_hub` layout and checks for the ".parleq-ready"
    /// sentinel that performDownload() writes after a successful download.
    public nonisolated static func readyMarkerExists(
        checkpoint: String,
        root: URL
    ) -> Bool {
        let dirName = checkpoint.replacingOccurrences(of: "/", with: "--")
        let markerURL = root
            .appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent(".parleq-ready")
        return FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// Returns true iff the on-disk ready-marker exists for the given
    /// checkpoint under the default models directory, WITHOUT touching any
    /// @MainActor state.
    ///
    /// Safe to call from any isolation context (including sync non-isolated
    /// functions such as ProviderRegistry.isConfigured).
    public nonisolated static func isReadyOnDisk(
        checkpoint: String = LocalModelDefaults.checkpoint
    ) -> Bool {
        readyMarkerExists(checkpoint: checkpoint, root: LocalModelDefaults.modelsDirectory)
    }

    /// On-disk byte size of `url`, or 0 if it doesn't exist. Used to decide
    /// skip/resume/fresh per file. Nonisolated — pure FileManager.
    nonisolated static func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    public init(checkpoint: String = LocalModelDefaults.checkpoint,
                rootDirectory: URL = LocalModelDefaults.modelsDirectory) {
        self.checkpoint = checkpoint
        self.modelDirectory = rootDirectory
            .appendingPathComponent(checkpoint.replacingOccurrences(of: "/", with: "--"),
                                    isDirectory: true)
        self.state = LocalModelStore.readyMarkerExists(checkpoint: checkpoint, root: rootDirectory)
            ? .ready : .notDownloaded
    }

    /// Cancels any in-flight download, then removes the model directory.
    /// Does not throw — FileManager errors are silently ignored (nothing to
    /// remove is not an error).
    public func remove() {
        downloadEpoch &+= 1   // invalidate any in-flight task's deferred writes
        downloadTask?.cancel()
        downloadTask = nil
        try? FileManager.default.removeItem(at: modelDirectory)
        state = .notDownloaded
    }

    public func download() {
        guard case .notDownloaded = state else { return }
        downloadEpoch &+= 1   // invalidate any previous task's deferred writes
        let myEpoch = downloadEpoch
        state = .downloading(progress: 0)

        downloadTask = Task {
            await performDownload(epoch: myEpoch)
        }
    }

    // MARK: - Private

    // MARK: epoch-guarded state writes
    // Only apply a terminal state if the captured epoch still matches the
    // current one. This closes the remove()+download() interleaving window:
    // if remove() and a fresh download() ran after this task suspended at an
    // await, the epoch will have advanced and this stale write is a no-op.
    private func applyTerminalState(_ newState: State, ifEpoch epoch: Int) {
        guard downloadEpoch == epoch else { return }
        state = newState
    }

    private func performDownload(epoch: Int) async {
        // We fetch the file list (+ per-file sizes) with HF's library, then
        // stream each file ourselves via HFStreamingDownloader. WHY not the
        // library's own download: macOS runs URLSession *download* tasks
        // out-of-process (nsurlsessiond) and only reports progress at whole-file
        // completion, so the multi-GB LFS shards froze the bar mid-shard (#87/#89).
        // Streaming the bytes in-process (URLSessionDataDelegate) makes progress
        // byte-accurate. Files still land directly under modelDirectory (no cache
        // subtree); remove() deletes the whole subtree (unchanged).
        let revision = "main"
        do {
            let client = HubClient(
                host: HubClient.defaultHost,
                bearerToken: nil,
                cache: nil
            )

            guard let repoID = Repo.ID(rawValue: checkpoint) else {
                applyTerminalState(.failed(message: "Invalid checkpoint identifier: \(checkpoint)"),
                                   ifEpoch: epoch)
                return
            }
            try FileManager.default.createDirectory(
                at: modelDirectory, withIntermediateDirectories: true)

            // 1. Fetch the file list (+ sizes) for the repo.
            let allEntries = try await client.listFiles(
                in: repoID, kind: .model, revision: revision, recursive: true)

            // Filter out repo metadata files that are not model weights.
            // .gitattributes is a Git LFS pointer-config file, not a model file.
            // README.md is documentation; filtered here too for a clean model dir.
            let fileEntries = allEntries.filter {
                $0.type == .file
                    && $0.path != ".gitattributes"
                    && $0.path != "README.md"
            }
            guard !fileEntries.isEmpty else {
                throw NSError(domain: "LocalModelStore", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Repository has no files"])
            }

            // 2. Plan each file: resolve URL, destination, expected size, and the
            //    skip/resume/fresh action from what's already on disk.
            var plans: [HFPlannedFile] = []
            var totalBytes: Int64 = 0
            for entry in fileEntries {
                // Defense-in-depth path-traversal guard: appendingPathComponent
                // does NOT resolve ".." on macOS, so a malicious entry path could
                // escape modelDirectory. Reject absolute paths or any ".." segment.
                if HFDownload.isUnsafeRepoPath(entry.path) {
                    applyTerminalState(
                        .failed(message: "Refusing unsafe file path in repository: \(entry.path)"),
                        ifEpoch: epoch)
                    return
                }
                let destination = modelDirectory.appendingPathComponent(entry.path)
                let expected = entry.size.map(Int64.init)
                let onDisk = Self.fileSize(at: destination)
                let action = HFDownload.plan(onDiskBytes: onDisk, expectedBytes: expected)
                let url = HFDownload.resolveURL(
                    host: HubClient.defaultHost,
                    namespace: repoID.namespace, name: repoID.name,
                    revision: revision, path: entry.path)
                plans.append(HFPlannedFile(
                    url: url, destination: destination, expectedBytes: expected, action: action))
                totalBytes += expected ?? 0
            }

            if Task.isCancelled {
                applyTerminalState(.notDownloaded, ifEpoch: epoch)
                return
            }
            // (No state reset here: download() already set .downloading(0) before
            // spawning this task, nothing has emitted progress yet, and a remove()
            // during the listFiles await is caught by the isCancelled check above.)

            // 3. Stream the bytes in-process. Progress writes don't need epoch
            //    guarding — an overwrite by a fresh task's .downloading is fine;
            //    only terminal states do, and the `case .downloading` guard below
            //    means a fraction never clobbers a terminal state set by
            //    remove()/cancel. No monotonicity guard: a resume that gets HTTP
            //    200 (server ignored Range) legitimately re-downloads from 0, so
            //    the bar must be free to dip and re-climb rather than freeze.
            try await HFStreamingDownloader().download(plans, totalBytes: totalBytes) {
                [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(progress: fraction)
                }
            }

            // 4. Write the ready marker only after all files have landed —
            //    and only if the task hasn't been cancelled mid-loop.
            if Task.isCancelled {
                applyTerminalState(.notDownloaded, ifEpoch: epoch)
                return
            }
            // Epoch-guard the marker write (TOCTOU): a remove() can run between
            // the Task.isCancelled check above and this write, bumping
            // downloadEpoch and recreating an empty modelDirectory. Without this
            // guard a cancelled task would drop a .parleq-ready marker into that
            // freshly-empty tree, and the next launch would read READY and fail
            // to load from an empty dir. Match the captured epoch (same predicate
            // applyTerminalState uses) so the marker is written ONLY when the
            // model files are present AND this task's epoch is still current.
            guard downloadEpoch == epoch else { return }
            let markerURL = modelDirectory.appendingPathComponent(readyMarker)
            try Data().write(to: markerURL)
            applyTerminalState(.ready, ifEpoch: epoch)
            print("[LocalModelStore] download complete: \(modelDirectory.path)")
        } catch is CancellationError {
            // Cancelled: leave partial files on disk (relaunch can resume);
            // don't mark as failed. Note: remove() deletes these files.
            applyTerminalState(.notDownloaded, ifEpoch: epoch)
        } catch {
            // Partial files are left on disk; a subsequent download() call
            // picks up where the prior attempt left off. remove() clears them.
            applyTerminalState(.failed(message: error.localizedDescription), ifEpoch: epoch)
            print("[LocalModelStore] download failed: \(error.localizedDescription)")
        }
    }
}
