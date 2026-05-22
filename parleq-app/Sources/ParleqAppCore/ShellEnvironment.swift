// ShellEnvironment — environment helpers for spawning CLI tools.
//
// macOS apps launched from Finder, Spotlight, the Dock, login items,
// or anything else that goes through launchd inherit a sparse
// environment. Notably, PATH is set to:
//
//     /usr/bin:/bin:/usr/sbin:/sbin
//
// — the system-only defaults. /opt/homebrew/bin (Apple Silicon
// Homebrew) and /usr/local/bin (Intel Homebrew + many official
// .pkg installers) are NOT included, even though every developer
// expects them to be (their interactive shell adds them via
// .zshrc / .bash_profile).
//
// When Parleq tries to exec a CLI tool that the user installed via
// Homebrew — `gcloud` for Vertex AI's ADC token, `az` for Azure's
// Entra ID token, both shipped via Homebrew — the exec returns
// 127 "No such file or directory" with stderr `env: gcloud: …` /
// `env: az: …`. The CLI works fine when the user invokes it in
// their terminal because their shell PATH includes the brew dirs;
// it just doesn't reach Parleq's child processes.
//
// `augmentedShellEnvironment()` returns a copy of the current
// environment with PATH prepended by the common install dirs, so
// any child process Parleq spawns can find user-installed CLIs
// regardless of launch method.

import Foundation

/// Common dirs where users install CLI tools, in priority order.
/// These are prepended to the inherited PATH so they win over
/// system-default locations — important because /usr/bin/python3
/// is not the same as /opt/homebrew/bin/python3, and a user who
/// configured one CLI for the brew version expects every spawned
/// process to find that version too.
private let extraPathDirs: [String] = [
    "/opt/homebrew/bin",   // Apple Silicon Homebrew default
    "/opt/homebrew/sbin",
    "/usr/local/bin",      // Intel Homebrew, official pkg installers
    "/usr/local/sbin",
]

/// Build a [String: String] suitable for `Process.environment`
/// that mirrors the parent process's env but with the common
/// CLI-install directories prepended to PATH. Never overrides an
/// inherited PATH entry — duplicates in PATH are harmless and the
/// existing user-customized entries (e.g. `~/.cargo/bin`) keep
/// their relative order after our additions.
///
/// Sendable / actor-agnostic — `ProcessInfo.environment` is safe
/// to read from any context, and the returned dictionary is a
/// fresh copy.
func augmentedShellEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let inheritedPath = env["PATH"] ?? ""
    let extras = extraPathDirs.joined(separator: ":")
    env["PATH"] = inheritedPath.isEmpty ? extras : "\(extras):\(inheritedPath)"
    return env
}
