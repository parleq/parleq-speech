// SidecarHealth — quick startup probe to confirm the FluidAudio
// sidecar is reachable, and a clear log message when it isn't.
//
// The sidecar is currently launched manually by the developer via
// scripts/start-fluidaudio.sh. Full auto-launch + supervision lands
// in M6 distribution (where we package the sidecar binary inside
// the .app bundle and run it as a child process). For M3-M5 the
// useful improvement is just to surface "sidecar not running" at
// startup instead of letting it manifest as a confusing ASR error
// on the first hotkey press.

import Foundation

enum SidecarHealth {
    /// Default health-check URL. Matches what the sidecar binary
    /// exposes at startup.
    static let defaultHealthURL = URL(string: "http://127.0.0.1:8767/health")!

    /// Run a single health probe with a tight timeout. Returns
    /// `true` if the sidecar responds 200 in time, `false`
    /// otherwise. Designed to be called on a background queue at
    /// app startup — never blocks longer than ~2 seconds.
    static func isHealthy(url: URL = defaultHealthURL, timeout: TimeInterval = 2.0) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return false
            }
            // Body should be `{"status":"ok"}`. We don't actually
            // care about the body content past "valid JSON of some
            // shape" — a 200 is the contract.
            return data.count > 0
        } catch {
            return false
        }
    }

    /// Console-friendly instructions for getting the sidecar up,
    /// printed when the startup probe fails.
    static let startupInstructions = """
        [parleq] FluidAudio sidecar isn't responding on http://127.0.0.1:8767.
        [parleq] Start it before using the hotkey:
        [parleq]   cd \(NSHomeDirectory())/Dev/parleq-speech
        [parleq]   ./scripts/start-fluidaudio.sh
        [parleq] (M6 will auto-launch this from the bundled .app — for now it's manual.)
        """
}
