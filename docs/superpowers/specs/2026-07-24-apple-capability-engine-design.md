# Apple Capability Engine for Lattice

**Date:** 2026-07-24
**Status:** Approved — ready for implementation planning
**Author:** Oli Mebberson (with ZCode)

## Problem

Lattice's README advertises support for adding Apple capabilities ("Shared App Groups or MusicKit"), but the codebase has **no structured capability support at all**. Investigation found:

- The only "catalog" is a prose list of examples in the LLM system prompt (`LLMService.swift:749-753`).
- The LLM is instructed to "do the file-side work yourself" — meaning it hand-writes `.entitlements` XML, Info.plist keys, and `project.pbxproj` file-reference wiring via generic `write_file`/`bash` tools.
- This is the riskiest kind of pbxproj edit (creating a `.entitlements` file + adding a `PBXFileReference` + `PBXBuildFile` + Resources build phase entry + `CODE_SIGN_ENTITLEMENTS` setting), and the *same* prompt elsewhere tells the model not to hand-roll pbxproj.
- Project templates ship with **no `.entitlements` files** (`ProjectTemplates/{ios,macos,watchos}/`), so even a simple capability requires full from-scratch wiring.
- MusicKit, CloudKit, and StoreKit appear **nowhere** in source despite being advertised.
- There is no `Capability` enum/struct, no entitlement-key table, no `add_capability` tool, and no UI to browse or toggle capabilities.

Result: capability correctness is unbounded — it depends entirely on the LLM getting the XML right each time.

## Solution

A structured, type-safe capability engine that replaces hand-written entitlements with a guaranteed-correct tool and UI. A static Swift catalog is the single source of truth for what each capability requires; a shared applicator applies and removes capabilities idempotently; both the chat tool and the Settings UI call the same engine.

## Architecture

Five new modules plus targeted edits to existing files:

```
AppleCapabilityCatalog.swift      [NEW] pure data — single source of truth for capability requirements
CapabilityApplicator.swift        [NEW] apply/remove — writes entitlements, Info.plist, build settings
CapabilityStatusChecker.swift     [NEW] read-only — reports which capabilities are currently active
PbxprojEditor.swift               [NEW] shared pbxproj-mutation helpers (extracted from ProjectAppIdentityEditor)
CapabilitySettingsView.swift      [NEW] SwiftUI toggle UI, added as a Section in the Identity editor
ToolExecutor.swift                [EDIT] add_capability + remove_capability cases
LLMService.swift                  [EDIT] system prompt: use the tool, don't hand-write entitlements
ProjectAppIdentityEditor.swift    [EDIT] delegate pbxproj mutation to shared PbxprojEditor
ContentView.swift                 [EDIT] +1 Section line pointing at CapabilitySettingsView
```

### Why this shape

- **Static Swift catalog** (chosen over JSON-driven) for type safety and because Apple's capability set is small and changes rarely — the extensibility cost of JSON isn't justified. Adding a capability is a ~15-line static constant.
- **Shared `PbxprojEditor`** (chosen over a separate engine) because `ProjectAppIdentityEditor` already contains a regex-based pbxproj editor that works. Capabilities need strictly more (file-reference wiring), so both should share one correct implementation rather than diverge.
- **Single engine for UI + tool** so there is exactly one place where capabilities are applied, and the UI never drifts from what the LLM can do.

## The Catalog

`AppleCapabilityCatalog.swift` is pure data with no I/O — trivially testable.

```swift
struct AppleCapability: Identifiable, Equatable {
    let id: String                      // "app_groups", "push_notifications"
    let displayName: String             // "App Groups"
    let summary: String                 // one-line user-facing description
    let entitlements: [EntitlementEntry]
    let infoPlistKeys: [PlistEntry]
    let frameworks: [String]            // declared but deferred in v1 (see Out of Scope)
    let provisioningNotes: String?      // what the user must do in Dev Portal / Xcode
    let applicablePlatforms: Set<Platform>
}

struct EntitlementEntry {
    let key: String                     // "com.apple.security.application-groups"
    let value: EntitlementValue
}

enum EntitlementValue {
    case string(String)                 // "development" / "production"
    case stringArray([String])          // group identifiers, keychain groups
    case boolean(Bool)
    case placeholder(String)            // "$(AppIdentifierPrefix)..." — resolved at apply time
}

struct PlistEntry {
    let key: String                     // "UIBackgroundModes"
    let value: Any                      // encoded via PropertyListSerialization
    let reasonKey: String?              // usage-description keys, e.g. "NSCameraUsageDescription"
}
```

### Initial catalog (5 capabilities)

Each hand-verified against Apple's documentation. iCloud/CloudKit was removed because its file-side work is inseparable from iCloud Container provisioning, which Lattice cannot automate — it would be a half-working capability. HealthKit, MusicKit, Associated Domains, and Widget Extensions are natural follow-ups.

1. **App Groups** — `com.apple.security.application-groups` (string array). Provisioning note: create the App Group in the Developer Portal and select it in Xcode > Signing & Capabilities.
2. **Push Notifications** — `aps-environment` entitlement + `UIBackgroundModes` plist key + `UserNotifications` framework declaration. Provisioning note: enable Push Notifications capability in Dev Portal and upload APNs key.
3. **StoreKit** — framework declaration only (no entitlement file key). Provisioning note: configure In-App Purchase in App Store Connect.
4. **Keychain Sharing** — `keychain-access-groups` (string array). Provisioning note: enable Keychain Sharing capability in Xcode.
5. **Background Modes** — `UIBackgroundModes` plist key only. No entitlement. No provisioning.

The struct's fields force the author of a new capability to consider *all* the places it touches, which is the correctness guarantee the hand-written approach lacks.

## The Apply Layer

`CapabilityApplicator` mirrors `ProjectAppIdentityEditor`: async funcs, regex-based pbxproj editing, atomic writes, typed errors. Responsibilities, in order:

1. **Locate the project and app target** — reuse the `applicationTargetConfigurationIDs` pattern (`ProjectAppIdentityEditor.swift:219`) via the shared `PbxprojEditor`.
2. **Ensure an entitlements file exists.** Check if `CODE_SIGN_ENTITLEMENTS` is already set; if not, create `<TargetName>.entitlements` next to the project and wire it in (PBXFileReference + PBXBuildFile + Resources build phase entry + build setting).
3. **Wire `CODE_SIGN_ENTITLEMENTS` into pbxproj** — the gap the current editor can't fill. Done via the shared `PbxprojEditor`.
4. **Merge entitlement keys** idempotently into the plist dictionary. Re-applying a capability never duplicates keys; arrays merge uniquely by value.
5. **Merge Info.plist keys** using the same plist-merge approach as `mergeInfoPlist` (`ProjectAppIdentityEditor.swift:185`).
6. **Declare frameworks in the catalog** but defer wiring (see Out of Scope). Surface a manual note when a capability declares frameworks.
7. **Return a structured result**:

```swift
struct CapabilityApplyResult {
    let changedFiles: [URL]
    let alreadyPresent: [String]        // keys that were already set
    let manualSteps: String?            // provisioning note surfaced to user/LLM
}

struct CapabilityRemoveResult {
    let changedFiles: [URL]
    let removedKeys: [String]
    let manualSteps: String?
}
```

### Idempotency (hard requirement)

- **Apply twice** for App Groups must not duplicate the array or create a second entitlements file. Every merge checks for existing keys first; array values are de-duplicated.
- **Remove** strips the capability's entitlement and plist keys per-key. It **never deletes the `.entitlements` file itself**, because that file may serve other capabilities. If the file becomes empty, it is left in place (Xcode requires the path to be valid).
- **Remove** of a shared plist key (e.g. `UIBackgroundModes`, used by both Push and Background Modes) is aware of which capability owns which keys via the catalog, so removing Background Modes does not strip a `UIBackgroundModes` entry that Push Notifications also relies on.

### Error handling

Mirrors `ProjectAppIdentityError`:

```swift
enum CapabilityApplicatorError: LocalizedError {
    case noXcodeProject
    case noApplicationTarget
    case unknownCapability(String)
    case missingParameter(String)        // e.g. app group identifier not provided
    case entitlementsWriteFailed(String)
    case pbxprojParseFailure(String)
    case notApplicableToPlatform(String, Platform)
}
```

## The `add_capability` / `remove_capability` Tools

New tools exposed to the LLM alongside the existing `bash` / `read_file` / `write_file` / `web_search` / `fetch_webpage`.

```json
{
  "name": "add_capability",
  "description": "Add an Apple capability to the current project. Updates entitlements, Info.plist, and project build settings correctly and idempotently. Use this instead of hand-editing entitlements or pbxproj for capabilities.",
  "input_schema": {
    "type": "object",
    "properties": {
      "capability": { "type": "string", "enum": ["app_groups", "push_notifications", "storekit", "keychain_sharing", "background_modes"] },
      "parameters": { "type": "object", "description": "Capability-specific values: app group identifiers, background modes array, aps environment, etc." }
    },
    "required": ["capability"]
  }
}
```

`remove_capability` takes the same `capability` id and strips the capability's keys.

- **Flow:** `ToolExecutor.execute(name:)` gains `add_capability` / `remove_capability` cases → resolves project root from the session context → calls `CapabilityApplicator.apply` / `remove` → returns the result summary (changed files + any manual steps) to the LLM as the tool output.
- **System prompt rewrite** (`LLMService.swift:749-753`): the old "do the file-side work yourself" guidance is replaced with "use `add_capability`; it handles entitlements, Info.plist, and build settings correctly. Only hand-edit project files for things outside the supported capability list." The catalog's capability ids are listed so the model knows what's available.
- **Validation:** unknown capability id → `unknownCapability` error. Missing required parameter → `missingParameter` error listing what's needed. Capability not applicable to the project's platform → `notApplicableToPlatform` error.

## The Capabilities UI

A new `CapabilitySettingsView.swift` added as a `Section` in the App Identity editor (near `ContentView.swift:6604`), sitting alongside the existing App Identity and Signing sections.

- **List view:** each capability as a row with a `Toggle`. Toggling on reveals a disclosure of required parameters (app group identifier text field, background modes checkboxes, aps environment picker, keychain groups).
- **Shared engine:** the UI calls the same `CapabilityApplicator` the tool uses — no duplicated logic.
- **Status source:** `CapabilityStatusChecker` is a read-only module that scans the project's current entitlements and Info.plist against the catalog and reports which capabilities are currently active. This is what makes the UI honest — toggles reflect actual project state rather than UI-only state that can drift.
- **Chat integration:** when a user adds a capability via chat (the LLM calls `add_capability`), the UI state refreshes because the section is driven by `CapabilityStatusChecker`, not by UI-local state.
- **File isolation:** the new view lives in `CapabilitySettingsView.swift`. ContentView only gains a one-line `Section { CapabilitySettingsView(...) }`. This is deliberate — the 282KB `ContentView.swift` must not grow.

## The Shared `PbxprojEditor`

Extracted from `ProjectAppIdentityEditor.swift` (`applicationTargetConfigurationIDs`, `blockRange(forConfigurationID:)`, `setOrInsertBuildSetting`, `hexIDs`, `pbxEscape`, `stripQuotes`). Both `ProjectAppIdentityEditor` and `CapabilityApplicator` call into it. The capabilities path additionally needs:

- **File reference creation** (`PBXFileReference` + `PBXBuildFile` + adding to the target's `Resources` build phase) for the `.entitlements` file.
- **`CODE_SIGN_ENTITLEMENTS` build setting** set/insert (handled by the existing `setOrInsertBuildSetting` once the helper is shared).

24-char hex ID generation for new pbxproj objects follows Xcode's convention. This is the riskiest code in the engine and gets the most test coverage.

## Key Guarantees

- **Idempotent** — applying twice never duplicates; removing is per-key and never deletes the shared entitlements file.
- **Type-safe** — the catalog forces every capability to model entitlements, plist keys, frameworks, and provisioning.
- **Single engine** — UI and chat tool share one applicator; no logic divergence.
- **Testable** — catalog and applicator are pure logic with no UI/AppKit dependencies.
- **Honest UI** — `CapabilityStatusChecker` reads actual project state, so toggles reflect reality.
- **Doesn't grow ContentView** — all new UI lives in its own file.

## Out of Scope (v1)

Explicitly deferred to keep v1 focused and correct:

- **Framework auto-wiring** — frameworks are declared in the catalog but not wired into pbxproj build phases in v1. A manual note is surfaced instead. Most Apple frameworks auto-link on modern Xcode; full `PBXBuildFile` + `PBXFrameworksBuildPhase` wiring is a follow-up.
- **Capabilities requiring Extension targets** — Widgets, Intents, Action Extensions, etc. These need a new target, not just entitlements. Separate effort.
- **iCloud / CloudKit** — removed from v1 because file-side work is inseparable from iCloud Container provisioning, which Lattice cannot automate. Would ship as a half-working capability.
- **HealthKit, MusicKit, Associated Domains** — natural follow-ups once the engine exists.
- **Apple Developer Portal automation** — Lattice surfaces manual steps as notes; it does not automate portal actions.

## Testing

- **Catalog validation tests** — every capability declares all required fields; ids are unique; applicablePlatforms is non-empty.
- **Applicator idempotency tests** — apply → apply again → assert no diff; apply → remove → apply → assert clean state. Run against fixture projects committed under a `Tests/Fixtures/` directory.
- **Remove safety tests** — removing one capability does not strip keys owned by another; removing never deletes the entitlements file.
- **Status checker tests** — given a fixture entitlements/plist, reports the correct active set.
- **PbxprojEditor tests** — file-reference creation produces parseable pbxproj; `CODE_SIGN_ENTITLEMENTS` is set on all app-target configs.

Tests are added as an XCTest target on the Lattice scheme (the project currently has no test target; creating one is part of this work).

## Acceptance Criteria

1. A user can open the Identity editor, toggle on "Push Notifications", provide an APNs environment, and the project builds with a valid `.entitlements` file and `UIBackgroundModes` in Info.plist.
2. Asking the LLM "add app groups with identifier group.com.example.app" results in an `add_capability` tool call (not hand-written XML), and the project reflects the change in the Identity editor on refresh.
3. Applying any capability twice produces no diff.
4. Removing a capability strips only its keys; other capabilities' keys remain.
5. The Identity editor's Capabilities section always reflects the true state of the project, even after changes made via chat.
6. `ContentView.swift` grows by only the Section wiring line; all new UI is in `CapabilitySettingsView.swift`.
