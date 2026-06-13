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
        // WHY Option B (per-file download) rather than Option A (HubCache inside
        // modelDirectory) or the original downloadSnapshot(cache: nil, to:…) call:
        //
        // The library's downloadSnapshot(…) private implementation has this guard
        // at the return path (swift-huggingface 0.9.0, HubClient+Files.swift ~L1379):
        //
        //   guard let cache else {
        //       throw HubCacheError.snapshotRequiresCacheOrDestination(…)
        //   }
        //
        // This guard fires AFTER all files have already been downloaded to the
        // destination directory — so cache:nil + to: downloads successfully but
        // then unconditionally throws on return, always landing in .failed.
        //
        // Option A (HubCache rooted inside modelDirectory) would avoid that throw
        // but HubCache uses the Python-compatible blob/refs layout, leaving a
        // .hub-cache/ subtree alongside the model weights. remove() would clean
        // it up (deletes all of modelDirectory), but it still writes cache
        // bookkeeping files alongside the model files, which is messier than needed.
        //
        // Option B (list + per-file download) is cleanest:
        //   • downloadFile(at:from:to:…) with an explicit destination URL works
        //     correctly without a cache — it downloads to a temp path then moves
        //     to the destination (see L714-727 in the same file).
        //   • Every byte lands directly under modelDirectory with no extra
        //     subdirectories or bookkeeping files.
        //   • Progress is tracked per-completed-file plus within-file via
        //     Foundation.Progress.
        //   • remove() deletes the whole modelDirectory subtree (unchanged).
        do {
            // cache: nil is safe here — we never call downloadSnapshot, so the
            // guard-at-return bug is not triggered.
            let client = HubClient(
                host: HubClient.defaultHost,
                bearerToken: nil,
                cache: nil
            )

            guard let repoID = Repo.ID(rawValue: checkpoint) else {
                // Repo.ID check is synchronous — no await has occurred, so the
                // epoch guard is not strictly needed here, but use it for consistency.
                applyTerminalState(.failed(message: "Invalid checkpoint identifier: \(checkpoint)"),
                                   ifEpoch: epoch)
                return
            }
            try FileManager.default.createDirectory(
                at: modelDirectory, withIntermediateDirectories: true)

            // 1. Fetch the file list for the repo.
            let allEntries = try await client.listFiles(
                in: repoID, kind: .model, revision: "main", recursive: true)

            // Filter out repo metadata files that are not model weights.
            // .gitattributes is a Git LFS pointer-config file, not a model file.
            // README.md is documentation; filtered here too for a clean model dir.
            let fileEntries = allEntries.filter {
                $0.type == .file
                    && $0.path != ".gitattributes"
                    && $0.path != "README.md"
            }
            let total = fileEntries.count
            guard total > 0 else {
                throw NSError(domain: "LocalModelStore", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Repository has no files"])
            }

            // 2. Download each file into modelDirectory, preserving sub-paths.
            for (index, entry) in fileEntries.enumerated() {
                // Check for cancellation before each file download. On cancel,
                // leave partial files on disk (a relaunch can resume where the
                // prior run left off) and reset state to .notDownloaded rather
                // than .failed. Note: remove() deletes these files.
                if Task.isCancelled {
                    applyTerminalState(.notDownloaded, ifEpoch: epoch)
                    return
                }

                // Defense-in-depth path-traversal guard (mirrors the library's
                // validateSnapshotEntryPath intent). appendingPathComponent does
                // NOT resolve ".." on macOS — it concatenates — so a malicious
                // entry.path ("/etc/…" or "../../…") could escape modelDirectory.
                // Risk is low (compile-time checkpoint, TLS to HF) but reject any
                // absolute path or path containing a ".." component before writing.
                let pathComponents = entry.path.split(separator: "/", omittingEmptySubsequences: false)
                if entry.path.hasPrefix("/") || pathComponents.contains("..") {
                    applyTerminalState(
                        .failed(message: "Refusing unsafe file path in repository: \(entry.path)"),
                        ifEpoch: epoch)
                    return
                }

                let destination = modelDirectory.appendingPathComponent(entry.path)
                // Progress is file-count-proportional, not byte-proportional —
                // small files advance the bar quickly; large shards crawl it.
                // Acceptable for v1; byte-weighting would need sizes from listFiles.
                let baseProgress = Double(index) / Double(total)
                let perFileProgress = Progress(totalUnitCount: 100)

                // Deliver coarse progress on MainActor immediately.
                // Progress writes don't need epoch guarding — an overwrite by a
                // fresh download task's .downloading is fine; only terminal states
                // (.notDownloaded / .failed) need the guard.
                state = .downloading(progress: baseProgress)

                // Observe per-file progress to give finer-grained updates.
                let observation = perFileProgress.observe(\.fractionCompleted,
                                                          options: [.new]) { [weak self] prog, _ in
                    guard let self else { return }
                    let withinFile = prog.fractionCompleted / Double(total)
                    let combined = min(baseProgress + withinFile, 1.0)
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(progress: combined)
                    }
                }
                defer { observation.invalidate() }

                _ = try await client.downloadFile(
                    at: entry.path,
                    from: repoID,
                    to: destination,
                    kind: .model,
                    revision: "main",
                    progress: perFileProgress
                )
            }

            // 3. Write the ready marker only after all files have landed —
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
