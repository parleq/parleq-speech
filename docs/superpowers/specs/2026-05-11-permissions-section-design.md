# Permissions section design

**Date:** 2026-05-11

## Goal

Add a status-aware Permissions section to Parleq that replaces the menu-bar "Open Login Items Settings…" entry removed in [PR #3](https://github.com/parleq/parleq-speech/pull/3) and also surfaces the macOS Microphone and Accessibility permissions Parleq depends on.

The section lives in two places:

- **Settings → Permissions** — a new sidebar section between "Usage" and "Advanced," for users browsing the app after first run.
- **Setup wizard → Permissions step** — a new wizard step between "Welcome" and "Pick provider," gating the wizard's Continue button until Microphone and Accessibility are granted. Open at Login stays optional.

The same `PermissionRow` component renders both surfaces so they behave identically.

## Non-goals

- Adding test infrastructure. Parleq has no XCTest suite today; introducing one is a separate decision.
- Revocation UX. When a permission is already granted, the "Manage…" button is rendered disabled. A future iteration may wire it to open the relevant System Settings pane so users can revoke from inside Parleq.
- Localization. Copy is English; the inline "Continue (grant X first)" reason is hand-written, not pluralized through a localization system.

## File layout

| File | Status | Purpose |
|---|---|---|
| `parleq-app/Sources/ParleqApp/Permissions.swift` | **new** | `@MainActor enum Permissions` — synchronous state probes for the three permissions, click handlers, and a small `PermissionState` enum. Mirrors the shape of `LoginItem.swift`. |
| `parleq-app/Sources/ParleqApp/PermissionRow.swift` | **new** | A reusable SwiftUI `PermissionRow` view. Renders the row from a `PermissionDescriptor` (title, subtitle, icon, current state, action label). |
| `parleq-app/Sources/ParleqApp/SettingsWindow.swift` | modified | Add `.permissions` case to `SettingsSection` (between `.usage` and `.advanced`) plus a `permissionsSection` view (~80 lines). |
| `parleq-app/Sources/ParleqApp/SetupWizard.swift` | modified | Add `.permissions` case to `WizardStep` (between `.welcome` and `.pickProvider`), add the step view, gate `canAdvance` on Microphone + Accessibility (~60 lines). |
| `parleq-app/Sources/ParleqApp/LoginItem.swift` | unchanged | Existing API surface (`isEnabled`, `isSupported`, `setEnabled`, `openLoginItemsSettings`) is sufficient. |
| `.gitignore` | modified | Add `.superpowers/` so the brainstorming companion's local files stay local. |

## State detection

A small `PermissionState` enum captures every visible state:

```swift
enum PermissionState {
    case granted
    case missing
    case notSupported  // only Open at Login can hit this (SMAppService .notFound on
                       // an unnotarized build or `swift run`)
}
```

Three probe functions, all synchronous and idempotent:

- **Microphone** → wraps `AVCaptureDevice.authorizationStatus(for: .audio)`. `.authorized` → `.granted`; everything else (`.notDetermined`, `.denied`, `.restricted`) → `.missing`.
- **Accessibility** → wraps `AXIsProcessTrusted()`. Note: this is the *non-prompting* variant. Calling `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` on every refresh would spam the system dialog; we only do that from the `.missing`-state click handler.
- **Open at Login** → `LoginItem.isEnabled` for granted-vs-not, `LoginItem.isSupported` to detect the SMAppService `.notFound` fallback that the user sees on a dev build (signed but unnotarized, or `swift run`).

A `PermissionsSnapshot` value type bundles the three:

```swift
struct PermissionsSnapshot: Equatable {
    let microphone: PermissionState
    let accessibility: PermissionState
    let openAtLogin: PermissionState
}
```

## PermissionsModel — refresh strategy

A tiny `final class PermissionsModel: ObservableObject` publishes the snapshot and re-polls on two triggers:

1. **`NSApplication.didBecomeActiveNotification`.** The dominant path: user clicks "Allow…", System Settings opens, they toggle a switch, ⌘-tab back to Parleq. `applicationDidBecomeActive` fires; the model re-snapshots; the pill flips to green.
2. **First appearance of the view** (`.onAppear` in both Settings and the wizard step). Catches the case where the user grants while Parleq was already foregrounded (rare but cheap — three synchronous calls).

No timers. No manual "Re-check" button. The Notification Center observer is added in `init` and torn down via the standard `deinit` removal.

The model is a singleton-ish — there should be one observer registration, not one per view. Implementation: a shared `static let shared = PermissionsModel()` accessed by both Settings and the wizard step.

## PermissionRow — UI contract

```swift
struct PermissionDescriptor {
    let icon: String              // SF Symbol name (e.g. "mic", "accessibility")
    let title: String             // "Microphone"
    let subtitle: String          // "Required to capture your speech."
    let state: PermissionState
    let primaryActionLabel: String  // "Allow…", "Turn on", "Open Login Items Settings…", etc.
    let onPrimaryAction: () -> Void
}
```

Per-row icons (SF Symbols, available on macOS 13+ which is below our minimum of 14.0):

| Row | SF Symbol |
|---|---|
| Microphone | `mic` |
| Accessibility | `accessibility` |
| Open at Login | `arrow.right.circle` |

`PermissionRow(descriptor:)` renders:
- Leading SF Symbol icon (slate, ~22pt).
- Title (semibold) and subtitle (12pt, muted) stacked.
- A flexible spacer.
- Trailing status pill — green "✓ Granted" / amber "⚠ Required" / grey "Off" / grey "Manual" depending on state and row kind.
- A button to the right of the pill. Disabled when `.granted` (label "Manage…", no-op handler). Primary-styled (amber) when Microphone/Accessibility are `.missing`. Standard button style for Open at Login and the `.notSupported` fallback.

## Click handlers per row × state

| Row | `.granted` | `.missing` | `.notSupported` |
|---|---|---|---|
| **Microphone** | Button disabled, "Manage…", no action. | "Allow…" → `AVCaptureDevice.requestAccess(for: .audio)` if `.notDetermined`; otherwise open `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`. | n/a |
| **Accessibility** | Button disabled, "Manage…", no action. | "Allow…" → `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` to fire the system dialog (which itself offers an "Open System Settings" link). Also open `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` as belt-and-suspenders so the user lands directly on the right pane. | n/a |
| **Open at Login** | Pill "On", button "Turn off" → `LoginItem.setEnabled(false)`. | Pill "Off", button "Turn on" → `LoginItem.setEnabled(true)` (fires SMAppService approval dialog the first time). | Pill "Manual", button "Open Login Items Settings…" → `LoginItem.openLoginItemsSettings()`. |

The Microphone request path needs care: `AVCaptureDevice.requestAccess` returns immediately `false` if the user has previously denied — the OS does not re-prompt. The click handler must check current state and route to System Settings in the `.denied` case rather than calling `requestAccess` blindly.

## Wizard gating

`SetupWizardView.canAdvance` for the `.permissions` step:

```swift
case .permissions:
    return model.snapshot.microphone == .granted
        && model.snapshot.accessibility == .granted
```

Open at Login is intentionally not in the gate — many users will leave it off, and we don't want to coerce.

The Continue button surfaces the blocking reason inline when disabled:

- If Microphone is missing: "Continue (grant Microphone first)"
- Else if Accessibility is missing: "Continue (grant Accessibility first)"
- Else: "Continue →"

When the user is bouncing between System Settings and the wizard, the snapshot updates via the `didBecomeActive` notification and the button label flips with no extra plumbing.

## SMAppService `.notFound` fallback

The current locally-installed build of Parleq is signed Developer ID but unnotarized (`make install` skips notarization for fast iteration); `make notarize` / `make release` produces the notarized variant. On the unnotarized variant `SMAppService.mainApp.status == .notFound` and the Open at Login row gracefully degrades to the "Manual" pill + "Open Login Items Settings…" button — the same fallback the menu-bar entry used to offer. Once the notarized .dmg is installed, the row flips to a normal toggle automatically.

This is preserved here because (a) the developer-build experience matters; (b) some users may install Parleq from a fork they signed themselves and benefit from the manual fallback too.

## Wizard step placement

Wizard order changes from `welcome → pickProvider → configureProvider → done` to `welcome → permissions → pickProvider → configureProvider → done`. Step indicator updates from "Step N of 4" to "Step N of 5". The progress pill renders Welcome → Permissions → Pick provider → Configure → Done across the top.

## Sidebar placement

`SettingsSection` enum order changes from `[hotkey, audio, behavior, paste, cleanup, dictionary, usage, advanced]` to `[hotkey, audio, behavior, paste, cleanup, dictionary, usage, permissions, advanced]`. SF Symbol icon: `lock.shield` (matches the section's purpose without colliding with `gearshape.2` used by Advanced).

## FAQ link

The Permissions section's footer carries one link: "What does Parleq do with these? See the FAQ →" pointing to `https://parleq.app/faq/#privacy-data-flow`. Same link inside the wizard step. The FAQ already has the detailed explanation; no copy duplication.

## Verification

No XCTest. Verification is `swift build` (smoke check that probes compile against the SDK) plus the 8-scenario manual smoke matrix:

1. Fresh install, neither granted. Both rows "Required"; click each "Allow…"; system prompts fire; pills flip to green on return.
2. Mic granted, Accessibility denied. Accessibility "Allow…" opens System Settings → Privacy → Accessibility. Toggle Parleq on; ⌘-tab back; pill flips via `didBecomeActive`.
3. Both granted. Two green pills, "Manage…" disabled, no noise.
4. Open at Login: off → on → off. SMAppService approval dialog fires on first "Turn on"; pill toggles correctly.
5. Open at Login `.notFound` (this dev build). Pill "Manual"; button opens Login Items Settings.
6. Wizard, first run, no permissions. Welcome → Permissions step. Continue disabled with inline reason; reason updates as each permission is granted; Continue enables after both.
7. Wizard, re-run with all granted. Permissions step shows three green pills; Continue immediately enabled.
8. Background grant. Open Settings to a non-Permissions section; in another app, revoke Mic via System Settings; return to Parleq; switch to Permissions section. Pill correctly shows "Required" (covered by the `.onAppear` refresh, not just `didBecomeActive`).

## Out of scope

- Polling. The two-trigger refresh is sufficient.
- An audit-log of permission grants/revocations.
- A "Reveal in System Settings" affordance on granted rows.
- Localization.
- Test infrastructure.
- Migration of any persisted state — there's none to migrate.
