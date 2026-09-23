# AGENTS.md — Monospace Notes

## Document Purpose

Provide the downstream coding agent with the exact authority, stack lock, execution order, validation gates, stop conditions, and honest completion vocabulary for this project.

## Required Reading Order

1. PRD.md for product scope and outcomes
2. ARD.md for architecture and ownership
3. TRD.md for locked technical contracts
4. TASKS.md for execution order
5. AGENTS.md for operating and completion rules

## Authority Hierarchy

1. The five-document packet as a single execution contract
2. PRD.md for product meaning and scope
3. ARD.md for architecture and ownership
4. TRD.md for technical and release decisions
5. TASKS.md for ordered implementation
6. Existing source only after it is created by the declared task

## Locked Stack

- Swift 6
- SwiftUI
- AppKit bridges where native macOS APIs require them
- Swift Package Manager
- Swift Testing
- UserDefaults

## Forbidden Substitutions

- Forbidden: iOS
- Forbidden: Catalyst
- Forbidden: Flutter
- Forbidden: Tauri
- Forbidden: Electron

## Locked Identity and Output

- Identity: com.monospace.notes
- Preset: native-macos-swiftui-desktop
- Runtime mode: native
- Artifact: native macOS .app and DMG
- Artifact path: dist/Monospace Notes.app

## Installation Rule

Install the verified signed app at /Applications/Monospace Notes.app after a scoped rollback copy, then register and launch that exact bundle through LaunchServices.

## Execution Rules

- Do not reinterpret the idea, add scope, switch stacks, rename IDs, or invent owners.
- Use the exact owner, implementation file, focused test, feature, contract, task, and phase mappings.
- Create files only in the task that first owns them and modify them only after creation.
- Implement failure, denied, cancellation, cleanup, persistence, credential, permission, lifecycle, and recovery paths before declaring a feature complete.
- Keep secrets out of source, logs, tests, fixtures, examples, commands, and generated artifacts.
- Preserve unrelated user work and stop if an undeclared conflict prevents the exact task.

## Runtime Architecture Rules

- Use an @main SwiftUI App entry with WindowGroup; one @Observable @MainActor AppState owns presentation state, feature services are injected at the composition root, and AppKit adapters remain in Platform owners.
- Run I/O and provider work in cancellable async tasks or actors off the main actor and publish UI state on the main actor.

## Integration Boundary

Standalone local application: no remote network endpoints, cloud credentials, or third-party web services are used.

## Recovery Rules

- Represent operations as idle, active, succeeded, failed, or cancelled and preserve the last valid user state.
- Use explicit user retries only; cancel tasks and close streams, file handles, delegates, and temporary resources on every terminal path.

## Lifecycle Rules

- Use WindowGroup as the Dock-first application entry.
- Cancel tasks and release AppKit delegates during application termination.
- Model window restoration only for product-owned state.

## Accessibility Rules

- Require VoiceOver and keyboard operation for every control, expose stable accessibility labels, roles, values, and focus order, and verify with SwiftUI accessibility tests plus Accessibility Inspector.

## Owner Map

- OWN-FOUNDATION — Foundation — Package.swift; Sources/MonospaceNotes/MonospaceNotesApp.swift; Sources/MonospaceNotes/AppState.swift; Tests/MonospaceNotesTests/ContractTests.swift — Tests/MonospaceNotesTests/ContractTests.swift — create PHASE-01-FOUNDATION — modify none
- OWN-DATA-STORE — DataStore — Sources/MonospaceNotes/Platform/DataStore.swift — Tests/MonospaceNotesTests/DataStoreTests.swift — create PHASE-02-DATA-STORE — modify none
- OWN-LIFECYCLE-COORDINATOR — LifecycleCoordinator — Sources/MonospaceNotes/Platform/LifecycleCoordinator.swift — Tests/MonospaceNotesTests/LifecycleCoordinatorTests.swift — create PHASE-03-LIFECYCLE-COORDINATOR — modify none
- OWN-COLD-LAUNCH-UNDER-100MS — ColdLaunchUnder100msFeature — Sources/MonospaceNotes/Features/ColdLaunchUnder100msFeature.swift — Tests/MonospaceNotesTests/ColdLaunchUnder100msFeatureTests.swift — create PHASE-04-COLD-LAUNCH-UNDER-100MS — modify none
- OWN-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — DarkMonochromaticWindowAppearanceFeature — Sources/MonospaceNotes/Features/DarkMonochromaticWindowAppearanceFeature.swift — Tests/MonospaceNotesTests/DarkMonochromaticWindowAppearanceFeatureTests.swift — create PHASE-05-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — modify none
- OWN-KEYSTROKE-RENDERING-UNDER-16MS — KeystrokeRenderingUnder16msFeature — Sources/MonospaceNotes/Features/KeystrokeRenderingUnder16msFeature.swift — Tests/MonospaceNotesTests/KeystrokeRenderingUnder16msFeatureTests.swift — create PHASE-06-KEYSTROKE-RENDERING-UNDER-16MS — modify none
- OWN-PERMISSION-COORDINATOR — PermissionCoordinator — Sources/MonospaceNotes/Platform/PermissionCoordinator.swift — Tests/MonospaceNotesTests/PermissionCoordinatorTests.swift — create PHASE-07-PERMISSION-COORDINATOR — modify none
- OWN-EXPLICIT-SAVE-WITH-CMD-S — ExplicitSaveWithCmdSFeature — Sources/MonospaceNotes/Features/ExplicitSaveWithCmdSFeature.swift — Tests/MonospaceNotesTests/ExplicitSaveWithCmdSFeatureTests.swift — create PHASE-08-EXPLICIT-SAVE-WITH-CMD-S — modify none
- OWN-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — FuzzySearchAcrossTheOpenWorkspaceFeature — Sources/MonospaceNotes/Features/FuzzySearchAcrossTheOpenWorkspaceFeature.swift — Tests/MonospaceNotesTests/FuzzySearchAcrossTheOpenWorkspaceFeatureTests.swift — create PHASE-09-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — modify none
- OWN-NON-BLOCKING-BACKGROUND-SAVE — NonBlockingBackgroundSaveFeature — Sources/MonospaceNotes/Features/NonBlockingBackgroundSaveFeature.swift — Tests/MonospaceNotesTests/NonBlockingBackgroundSaveFeatureTests.swift — create PHASE-10-NON-BLOCKING-BACKGROUND-SAVE — modify none
- OWN-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — OpenAndEditAPlainTextNoteFeature — Sources/MonospaceNotes/Features/OpenAndEditAPlainTextNoteFeature.swift — Tests/MonospaceNotesTests/OpenAndEditAPlainTextNoteFeatureTests.swift — create PHASE-11-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — modify none
- OWN-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — OpenAndSavePanelsForLocalFilesystemAccessFeature — Sources/MonospaceNotes/Features/OpenAndSavePanelsForLocalFilesystemAccessFeature.swift — Tests/MonospaceNotesTests/OpenAndSavePanelsForLocalFilesystemAccessFeatureTests.swift — create PHASE-12-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — modify none
- OWN-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — PersistTypographyAndKeybindingsInUserdefaultsFeature — Sources/MonospaceNotes/Features/PersistTypographyAndKeybindingsInUserdefaultsFeature.swift — Tests/MonospaceNotesTests/PersistTypographyAndKeybindingsInUserdefaultsFeatureTests.swift — create PHASE-13-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — modify none
- OWN-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — SettingsWindowForTypographyAndKeybindingsFeature — Sources/MonospaceNotes/Features/SettingsWindowForTypographyAndKeybindingsFeature.swift — Tests/MonospaceNotesTests/SettingsWindowForTypographyAndKeybindingsFeatureTests.swift — create PHASE-14-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — modify none
- OWN-PACKAGING — Packaging — Scripts/package_app.sh — Tests/MonospaceNotesTests/PackagingContractTests.swift — create PHASE-15-PACKAGING — modify none

## Required Phase Order

1. PHASE-01-FOUNDATION: Locked foundation; depends on nothing; tasks TASK-01-FOUNDATION
2. PHASE-02-DATA-STORE: DataStore; depends on PHASE-01-FOUNDATION; tasks TASK-02-DATA-STORE
3. PHASE-03-LIFECYCLE-COORDINATOR: LifecycleCoordinator; depends on PHASE-01-FOUNDATION; tasks TASK-03-LIFECYCLE-COORDINATOR
4. PHASE-04-COLD-LAUNCH-UNDER-100MS: ColdLaunchUnder100msFeature; depends on PHASE-01-FOUNDATION, PHASE-02-DATA-STORE, PHASE-03-LIFECYCLE-COORDINATOR; tasks TASK-04-COLD-LAUNCH-UNDER-100MS
5. PHASE-05-DARK-MONOCHROMATIC-WINDOW-APPEARANCE: DarkMonochromaticWindowAppearanceFeature; depends on PHASE-01-FOUNDATION, PHASE-02-DATA-STORE, PHASE-03-LIFECYCLE-COORDINATOR; tasks TASK-05-DARK-MONOCHROMATIC-WINDOW-APPEARANCE
6. PHASE-06-KEYSTROKE-RENDERING-UNDER-16MS: KeystrokeRenderingUnder16msFeature; depends on PHASE-01-FOUNDATION, PHASE-02-DATA-STORE, PHASE-03-LIFECYCLE-COORDINATOR; tasks TASK-06-KEYSTROKE-RENDERING-UNDER-16MS
7. PHASE-07-PERMISSION-COORDINATOR: PermissionCoordinator; depends on PHASE-01-FOUNDATION; tasks TASK-07-PERMISSION-COORDINATOR
8. PHASE-08-EXPLICIT-SAVE-WITH-CMD-S: ExplicitSaveWithCmdSFeature; depends on PHASE-01-FOUNDATION, PHASE-02-DATA-STORE, PHASE-03-LIFECYCLE-COORDINATOR, PHASE-07-PERMISSION-COORDINATOR; tasks TASK-08-EXPLICIT-SAVE-WITH-CMD-S
9. PHASE-09-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE: FuzzySearchAcrossTheOpenWorkspaceFeature; depends on PHASE-01-FOUNDATION, PHASE-02-DATA-STORE, PHASE-03-LIFECYCLE-COORDINATOR, PHASE-07-PERMISSION-COORDINATOR; tasks TASK-09-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE
10. PHASE-10-NON-BLOCKING-BACKGROUND-SAVE: NonBlockingBackgroundSaveFeature; depends on PHASE-01-FOUNDATION, PHASE-02-DATA-STORE, PHASE-03-LIFECYCLE-COORDINATOR, PHASE-07-PERMISSION-COORDINATOR; tasks TASK-10-NON-BLOCKING-BACKGROUND-SAVE
11. PHASE-11-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE: OpenAndEditAPlainTextNoteFeature; depends on PHASE-01-FOUNDATION, PHASE-02-DATA-STORE, PHASE-03-LIFECYCLE-COORDINATOR, PHASE-07-PERMISSION-COORDINATOR; tasks TASK-11-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE
12. PHASE-12-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS: OpenAndSavePanelsForLocalFilesystemAccessFeature; depends on PHASE-01-FOUNDATION, PHASE-02-DATA-STORE, PHASE-03-LIFECYCLE-COORDINATOR, PHASE-07-PERMISSION-COORDINATOR; tasks TASK-12-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
13. PHASE-13-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS: PersistTypographyAndKeybindingsInUserdefaultsFeature; depends on PHASE-01-FOUNDATION, PHASE-02-DATA-STORE, PHASE-03-LIFECYCLE-COORDINATOR; tasks TASK-13-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS
14. PHASE-14-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS: SettingsWindowForTypographyAndKeybindingsFeature; depends on PHASE-01-FOUNDATION, PHASE-02-DATA-STORE, PHASE-03-LIFECYCLE-COORDINATOR; tasks TASK-14-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS
15. PHASE-15-PACKAGING: Packaging; depends on PHASE-01-FOUNDATION, PHASE-04-COLD-LAUNCH-UNDER-100MS, PHASE-05-DARK-MONOCHROMATIC-WINDOW-APPEARANCE, PHASE-02-DATA-STORE, PHASE-08-EXPLICIT-SAVE-WITH-CMD-S, PHASE-09-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE, PHASE-06-KEYSTROKE-RENDERING-UNDER-16MS, PHASE-03-LIFECYCLE-COORDINATOR, PHASE-10-NON-BLOCKING-BACKGROUND-SAVE, PHASE-11-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE, PHASE-12-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS, PHASE-07-PERMISSION-COORDINATOR, PHASE-13-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS, PHASE-14-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS; tasks TASK-15-PACKAGING

## Validation Gates

1. Run `swift test` and require exit status zero.
2. Run `swift build -c release` and require exit status zero.
3. Run `./Scripts/package_app.sh` and require exit status zero.
4. Run `codesign --verify --deep --strict "dist/Monospace Notes.app"` and require exit status zero.
5. Run `open "dist/Monospace Notes.app"` and require exit status zero.

## Stop Conditions

- Stop when a requested implementation decision is absent from all five documents.
- Stop when an ID, owner, file, focused test, dependency, or command conflicts across documents.
- Stop when a task would modify a file before its create task.
- Stop when a forbidden technology or undeclared remote service is required.
- Stop when a relevant test, build, package, signing, install, or launch check fails after root-cause diagnosis.
- Report the exact blocker without claiming completion.

## Completion Reporting

- DONE: every declared feature and contract is implemented, every required command passed, the artifact was verified, and no required work remains.
- PARTIAL: safe implemented work is verified but a named external proof or user-controlled action remains; list it precisely.
- BLOCKED: an exact missing authority, unavailable dependency, unsafe conflict, or repeated external failure prevents further safe progress; include the failing command and next action.

## Review Checklist

- Product and non-goal boundaries match PRD.md.
- Architecture and state ownership match ARD.md.
- Stack, files, contracts, permissions, persistence, credentials, lifecycle, recovery, packaging, and signing match TRD.md.
- Task and phase ordering match TASKS.md.
- Focused tests and every final command passed with fresh output.

## Traceability Index

- FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — Open and edit a plain-text note — Requirement REQ-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — Acceptance ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-01, ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-02, ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-03, ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-04 — Owner OWN-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — Contracts CON-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-INTERFACE, CON-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-RECOVERY, CON-DATA-NOTE-FILE, CON-DATA-OPEN-DOCUMENT-BUFFER, CON-DATA-TYPOGRAPHY-SETTINGS, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-NOTE-FILE, CON-PERSISTENCE-OPEN-DOCUMENT-BUFFER, CON-PERSISTENCE-TYPOGRAPHY-SETTINGS, CON-PERMISSION-FILESYSTEM, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/MonospaceNotes/Features/OpenAndEditAPlainTextNoteFeature.swift; Tests/MonospaceNotesTests/OpenAndEditAPlainTextNoteFeatureTests.swift — Phase PHASE-11-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — Task TASK-11-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE depends on TASK-01-FOUNDATION, TASK-02-DATA-STORE, TASK-03-LIFECYCLE-COORDINATOR, TASK-07-PERMISSION-COORDINATOR
- FEAT-EXPLICIT-SAVE-WITH-CMD-S — Explicit save with Cmd+S — Requirement REQ-EXPLICIT-SAVE-WITH-CMD-S — Acceptance ACC-EXPLICIT-SAVE-WITH-CMD-S-01, ACC-EXPLICIT-SAVE-WITH-CMD-S-02, ACC-EXPLICIT-SAVE-WITH-CMD-S-03, ACC-EXPLICIT-SAVE-WITH-CMD-S-04 — Owner OWN-EXPLICIT-SAVE-WITH-CMD-S — Contracts CON-EXPLICIT-SAVE-WITH-CMD-S-INTERFACE, CON-EXPLICIT-SAVE-WITH-CMD-S-RECOVERY, CON-DATA-NOTE-FILE, CON-DATA-TEMPORARY-SAVE-FILE, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-NOTE-FILE, CON-PERSISTENCE-TEMPORARY-SAVE-FILE, CON-PERMISSION-FILESYSTEM, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/MonospaceNotes/Features/ExplicitSaveWithCmdSFeature.swift; Tests/MonospaceNotesTests/ExplicitSaveWithCmdSFeatureTests.swift — Phase PHASE-08-EXPLICIT-SAVE-WITH-CMD-S — Task TASK-08-EXPLICIT-SAVE-WITH-CMD-S depends on TASK-01-FOUNDATION, TASK-02-DATA-STORE, TASK-03-LIFECYCLE-COORDINATOR, TASK-07-PERMISSION-COORDINATOR
- FEAT-NON-BLOCKING-BACKGROUND-SAVE — Non-blocking background save — Requirement REQ-NON-BLOCKING-BACKGROUND-SAVE — Acceptance ACC-NON-BLOCKING-BACKGROUND-SAVE-01, ACC-NON-BLOCKING-BACKGROUND-SAVE-02, ACC-NON-BLOCKING-BACKGROUND-SAVE-03, ACC-NON-BLOCKING-BACKGROUND-SAVE-04 — Owner OWN-NON-BLOCKING-BACKGROUND-SAVE — Contracts CON-NON-BLOCKING-BACKGROUND-SAVE-INTERFACE, CON-NON-BLOCKING-BACKGROUND-SAVE-RECOVERY, CON-DATA-NOTE-FILE, CON-DATA-OPEN-DOCUMENT-BUFFER, CON-DATA-TEMPORARY-SAVE-FILE, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-NOTE-FILE, CON-PERSISTENCE-OPEN-DOCUMENT-BUFFER, CON-PERSISTENCE-TEMPORARY-SAVE-FILE, CON-PERMISSION-FILESYSTEM, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/MonospaceNotes/Features/NonBlockingBackgroundSaveFeature.swift; Tests/MonospaceNotesTests/NonBlockingBackgroundSaveFeatureTests.swift — Phase PHASE-10-NON-BLOCKING-BACKGROUND-SAVE — Task TASK-10-NON-BLOCKING-BACKGROUND-SAVE depends on TASK-01-FOUNDATION, TASK-02-DATA-STORE, TASK-03-LIFECYCLE-COORDINATOR, TASK-07-PERMISSION-COORDINATOR
- FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — Fuzzy search across the open workspace — Requirement REQ-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — Acceptance ACC-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-01, ACC-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-02, ACC-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-03, ACC-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-04 — Owner OWN-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — Contracts CON-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-INTERFACE, CON-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-RECOVERY, CON-DATA-NOTE-FILE, CON-DATA-OPEN-DOCUMENT-BUFFER, CON-DATA-WORKSPACE-FOLDER-REFERENCE, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-NOTE-FILE, CON-PERSISTENCE-OPEN-DOCUMENT-BUFFER, CON-PERSISTENCE-WORKSPACE-FOLDER-REFERENCE, CON-PERMISSION-FILESYSTEM, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/MonospaceNotes/Features/FuzzySearchAcrossTheOpenWorkspaceFeature.swift; Tests/MonospaceNotesTests/FuzzySearchAcrossTheOpenWorkspaceFeatureTests.swift — Phase PHASE-09-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — Task TASK-09-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE depends on TASK-01-FOUNDATION, TASK-02-DATA-STORE, TASK-03-LIFECYCLE-COORDINATOR, TASK-07-PERMISSION-COORDINATOR
- FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — Settings window for typography and keybindings — Requirement REQ-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — Acceptance ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-01, ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-02, ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-03, ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-04 — Owner OWN-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — Contracts CON-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-INTERFACE, CON-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-RECOVERY, CON-DATA-TYPOGRAPHY-SETTINGS, CON-DATA-KEYBINDING-SETTINGS, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-TYPOGRAPHY-SETTINGS, CON-PERSISTENCE-KEYBINDING-SETTINGS, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/MonospaceNotes/Features/SettingsWindowForTypographyAndKeybindingsFeature.swift; Tests/MonospaceNotesTests/SettingsWindowForTypographyAndKeybindingsFeatureTests.swift — Phase PHASE-14-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — Task TASK-14-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS depends on TASK-01-FOUNDATION, TASK-02-DATA-STORE, TASK-03-LIFECYCLE-COORDINATOR
- FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — Persist typography and keybindings in UserDefaults — Requirement REQ-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — Acceptance ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-01, ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-02, ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-03, ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-04 — Owner OWN-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — Contracts CON-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-INTERFACE, CON-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-RECOVERY, CON-DATA-TYPOGRAPHY-SETTINGS, CON-DATA-KEYBINDING-SETTINGS, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-TYPOGRAPHY-SETTINGS, CON-PERSISTENCE-KEYBINDING-SETTINGS, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/MonospaceNotes/Features/PersistTypographyAndKeybindingsInUserdefaultsFeature.swift; Tests/MonospaceNotesTests/PersistTypographyAndKeybindingsInUserdefaultsFeatureTests.swift — Phase PHASE-13-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — Task TASK-13-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS depends on TASK-01-FOUNDATION, TASK-02-DATA-STORE, TASK-03-LIFECYCLE-COORDINATOR
- FEAT-COLD-LAUNCH-UNDER-100MS — Cold launch under 100ms — Requirement REQ-COLD-LAUNCH-UNDER-100MS — Acceptance ACC-COLD-LAUNCH-UNDER-100MS-01, ACC-COLD-LAUNCH-UNDER-100MS-02, ACC-COLD-LAUNCH-UNDER-100MS-03, ACC-COLD-LAUNCH-UNDER-100MS-04 — Owner OWN-COLD-LAUNCH-UNDER-100MS — Contracts CON-COLD-LAUNCH-UNDER-100MS-INTERFACE, CON-COLD-LAUNCH-UNDER-100MS-RECOVERY, CON-DATA-TYPOGRAPHY-SETTINGS, CON-DATA-KEYBINDING-SETTINGS, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-TYPOGRAPHY-SETTINGS, CON-PERSISTENCE-KEYBINDING-SETTINGS, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/MonospaceNotes/Features/ColdLaunchUnder100msFeature.swift; Tests/MonospaceNotesTests/ColdLaunchUnder100msFeatureTests.swift — Phase PHASE-04-COLD-LAUNCH-UNDER-100MS — Task TASK-04-COLD-LAUNCH-UNDER-100MS depends on TASK-01-FOUNDATION, TASK-02-DATA-STORE, TASK-03-LIFECYCLE-COORDINATOR
- FEAT-KEYSTROKE-RENDERING-UNDER-16MS — Keystroke rendering under 16ms — Requirement REQ-KEYSTROKE-RENDERING-UNDER-16MS — Acceptance ACC-KEYSTROKE-RENDERING-UNDER-16MS-01, ACC-KEYSTROKE-RENDERING-UNDER-16MS-02, ACC-KEYSTROKE-RENDERING-UNDER-16MS-03, ACC-KEYSTROKE-RENDERING-UNDER-16MS-04 — Owner OWN-KEYSTROKE-RENDERING-UNDER-16MS — Contracts CON-KEYSTROKE-RENDERING-UNDER-16MS-INTERFACE, CON-KEYSTROKE-RENDERING-UNDER-16MS-RECOVERY, CON-DATA-OPEN-DOCUMENT-BUFFER, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-OPEN-DOCUMENT-BUFFER, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/MonospaceNotes/Features/KeystrokeRenderingUnder16msFeature.swift; Tests/MonospaceNotesTests/KeystrokeRenderingUnder16msFeatureTests.swift — Phase PHASE-06-KEYSTROKE-RENDERING-UNDER-16MS — Task TASK-06-KEYSTROKE-RENDERING-UNDER-16MS depends on TASK-01-FOUNDATION, TASK-02-DATA-STORE, TASK-03-LIFECYCLE-COORDINATOR
- FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — Open and save panels for local filesystem access — Requirement REQ-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — Acceptance ACC-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-01, ACC-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-02, ACC-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-03, ACC-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-04 — Owner OWN-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — Contracts CON-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-INTERFACE, CON-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-RECOVERY, CON-DATA-NOTE-FILE, CON-DATA-TEMPORARY-SAVE-FILE, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-NOTE-FILE, CON-PERSISTENCE-TEMPORARY-SAVE-FILE, CON-PERMISSION-FILESYSTEM, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/MonospaceNotes/Features/OpenAndSavePanelsForLocalFilesystemAccessFeature.swift; Tests/MonospaceNotesTests/OpenAndSavePanelsForLocalFilesystemAccessFeatureTests.swift — Phase PHASE-12-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — Task TASK-12-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS depends on TASK-01-FOUNDATION, TASK-02-DATA-STORE, TASK-03-LIFECYCLE-COORDINATOR, TASK-07-PERMISSION-COORDINATOR
- FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — Dark monochromatic window appearance — Requirement REQ-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — Acceptance ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-01, ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-02, ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-03, ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-04 — Owner OWN-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — Contracts CON-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-INTERFACE, CON-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-RECOVERY, CON-DATA-TYPOGRAPHY-SETTINGS, CON-LIFECYCLE-PRESET, CON-PERSISTENCE-TYPOGRAPHY-SETTINGS, CON-SECURITY-BOUNDARY, CON-PACKAGING-RELEASE — Files Sources/MonospaceNotes/Features/DarkMonochromaticWindowAppearanceFeature.swift; Tests/MonospaceNotesTests/DarkMonochromaticWindowAppearanceFeatureTests.swift — Phase PHASE-05-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — Task TASK-05-DARK-MONOCHROMATIC-WINDOW-APPEARANCE depends on TASK-01-FOUNDATION, TASK-02-DATA-STORE, TASK-03-LIFECYCLE-COORDINATOR
- REQ-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — Feature FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — The app reads the selected .txt file as UTF-8 text and displays it in a TextKit 2 text view with the configured monospace font and point size. The window title shows the file name. Editing modifies the in-memory text buffer and marks the document as having unsaved changes.
- REQ-EXPLICIT-SAVE-WITH-CMD-S — Feature FEAT-EXPLICIT-SAVE-WITH-CMD-S — The app writes the current buffer to the document's file path as UTF-8 text. If the document has no path, the app presents a save panel and uses the chosen path. On success, the unsaved-changes marker is cleared. The write replaces the destination by renaming a temporary file in the same directory.
- REQ-NON-BLOCKING-BACKGROUND-SAVE — Feature FEAT-NON-BLOCKING-BACKGROUND-SAVE — The app writes the buffer to a temporary file in the same directory as the destination, then replaces the destination by renaming the temporary file over it. The write and rename run off the main thread so the text view remains responsive to keystrokes.
- REQ-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — Feature FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — The app matches the query against note file names and note contents in the currently open workspace folder using a fuzzy subsequence match, and lists matching notes ordered by match score. Selecting a result opens that note.
- REQ-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — Feature FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — The app opens a Settings window with controls for font family, point size, and keybinding assignments. Changes apply to the open document immediately and are written to UserDefaults.
- REQ-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — Feature FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — The app reads typography and keybinding values from UserDefaults at launch and writes them whenever they change. Missing values fall back to the defaults: font family Menlo, point size 13, and Cmd+S for save.
- REQ-COLD-LAUNCH-UNDER-100MS — Feature FEAT-COLD-LAUNCH-UNDER-100MS — The app initializes its window, text view, and settings from UserDefaults and presents an editable document window. No network calls or remote resource loads occur during launch.
- REQ-KEYSTROKE-RENDERING-UNDER-16MS — Feature FEAT-KEYSTROKE-RENDERING-UNDER-16MS — The app inserts the character into the text buffer and lays out and draws the updated text using TextKit 2. The main thread performs no file I/O during keystroke handling.
- REQ-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — Feature FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — The app presents the standard macOS open or save panel restricted to .txt files. The chosen path is used for reading or writing the note. The app does not access paths outside the user's selection. The write replaces the destination by renaming a temporary file in the same directory.
- REQ-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — Feature FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — The window background is #000000 and the text is rendered in the configured monospace font at the configured point size with a foreground color that meets a contrast ratio of at least 7:1 against #000000.
- ACC-COLD-LAUNCH-UNDER-100MS-01 — feature — Features FEAT-COLD-LAUNCH-UNDER-100MS — Owner OWN-COLD-LAUNCH-UNDER-100MS
- ACC-COLD-LAUNCH-UNDER-100MS-02 — feature — Features FEAT-COLD-LAUNCH-UNDER-100MS — Owner OWN-COLD-LAUNCH-UNDER-100MS
- ACC-COLD-LAUNCH-UNDER-100MS-03 — feature — Features FEAT-COLD-LAUNCH-UNDER-100MS — Owner OWN-COLD-LAUNCH-UNDER-100MS
- ACC-COLD-LAUNCH-UNDER-100MS-04 — feature — Features FEAT-COLD-LAUNCH-UNDER-100MS — Owner OWN-COLD-LAUNCH-UNDER-100MS
- ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-01 — feature — Features FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — Owner OWN-DARK-MONOCHROMATIC-WINDOW-APPEARANCE
- ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-02 — feature — Features FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — Owner OWN-DARK-MONOCHROMATIC-WINDOW-APPEARANCE
- ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-03 — feature — Features FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — Owner OWN-DARK-MONOCHROMATIC-WINDOW-APPEARANCE
- ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-04 — feature — Features FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — Owner OWN-DARK-MONOCHROMATIC-WINDOW-APPEARANCE
- ACC-EXPLICIT-SAVE-WITH-CMD-S-01 — feature — Features FEAT-EXPLICIT-SAVE-WITH-CMD-S — Owner OWN-EXPLICIT-SAVE-WITH-CMD-S
- ACC-EXPLICIT-SAVE-WITH-CMD-S-02 — feature — Features FEAT-EXPLICIT-SAVE-WITH-CMD-S — Owner OWN-EXPLICIT-SAVE-WITH-CMD-S
- ACC-EXPLICIT-SAVE-WITH-CMD-S-03 — feature — Features FEAT-EXPLICIT-SAVE-WITH-CMD-S — Owner OWN-EXPLICIT-SAVE-WITH-CMD-S
- ACC-EXPLICIT-SAVE-WITH-CMD-S-04 — feature — Features FEAT-EXPLICIT-SAVE-WITH-CMD-S — Owner OWN-EXPLICIT-SAVE-WITH-CMD-S
- ACC-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-01 — feature — Features FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — Owner OWN-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE
- ACC-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-02 — feature — Features FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — Owner OWN-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE
- ACC-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-03 — feature — Features FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — Owner OWN-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE
- ACC-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-04 — feature — Features FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — Owner OWN-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE
- ACC-KEYSTROKE-RENDERING-UNDER-16MS-01 — feature — Features FEAT-KEYSTROKE-RENDERING-UNDER-16MS — Owner OWN-KEYSTROKE-RENDERING-UNDER-16MS
- ACC-KEYSTROKE-RENDERING-UNDER-16MS-02 — feature — Features FEAT-KEYSTROKE-RENDERING-UNDER-16MS — Owner OWN-KEYSTROKE-RENDERING-UNDER-16MS
- ACC-KEYSTROKE-RENDERING-UNDER-16MS-03 — feature — Features FEAT-KEYSTROKE-RENDERING-UNDER-16MS — Owner OWN-KEYSTROKE-RENDERING-UNDER-16MS
- ACC-KEYSTROKE-RENDERING-UNDER-16MS-04 — feature — Features FEAT-KEYSTROKE-RENDERING-UNDER-16MS — Owner OWN-KEYSTROKE-RENDERING-UNDER-16MS
- ACC-NON-BLOCKING-BACKGROUND-SAVE-01 — feature — Features FEAT-NON-BLOCKING-BACKGROUND-SAVE — Owner OWN-NON-BLOCKING-BACKGROUND-SAVE
- ACC-NON-BLOCKING-BACKGROUND-SAVE-02 — feature — Features FEAT-NON-BLOCKING-BACKGROUND-SAVE — Owner OWN-NON-BLOCKING-BACKGROUND-SAVE
- ACC-NON-BLOCKING-BACKGROUND-SAVE-03 — feature — Features FEAT-NON-BLOCKING-BACKGROUND-SAVE — Owner OWN-NON-BLOCKING-BACKGROUND-SAVE
- ACC-NON-BLOCKING-BACKGROUND-SAVE-04 — feature — Features FEAT-NON-BLOCKING-BACKGROUND-SAVE — Owner OWN-NON-BLOCKING-BACKGROUND-SAVE
- ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-01 — feature — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — Owner OWN-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE
- ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-02 — feature — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — Owner OWN-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE
- ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-03 — feature — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — Owner OWN-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE
- ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-04 — feature — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — Owner OWN-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE
- ACC-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-01 — feature — Features FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — Owner OWN-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
- ACC-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-02 — feature — Features FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — Owner OWN-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
- ACC-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-03 — feature — Features FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — Owner OWN-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
- ACC-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-04 — feature — Features FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — Owner OWN-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
- ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-01 — feature — Features FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — Owner OWN-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS
- ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-02 — feature — Features FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — Owner OWN-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS
- ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-03 — feature — Features FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — Owner OWN-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS
- ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-04 — feature — Features FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — Owner OWN-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS
- ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-01 — feature — Features FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — Owner OWN-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS
- ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-02 — feature — Features FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — Owner OWN-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS
- ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-03 — feature — Features FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — Owner OWN-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS
- ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-04 — feature — Features FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — Owner OWN-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS
- CON-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-INTERFACE — Open and edit a plain-text note interface (interface) — Owner OWN-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE
- CON-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-RECOVERY — Open and edit a plain-text note recovery (recovery) — Owner OWN-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE
- CON-EXPLICIT-SAVE-WITH-CMD-S-INTERFACE — Explicit save with Cmd+S interface (interface) — Owner OWN-EXPLICIT-SAVE-WITH-CMD-S — Features FEAT-EXPLICIT-SAVE-WITH-CMD-S
- CON-EXPLICIT-SAVE-WITH-CMD-S-RECOVERY — Explicit save with Cmd+S recovery (recovery) — Owner OWN-EXPLICIT-SAVE-WITH-CMD-S — Features FEAT-EXPLICIT-SAVE-WITH-CMD-S
- CON-NON-BLOCKING-BACKGROUND-SAVE-INTERFACE — Non-blocking background save interface (interface) — Owner OWN-NON-BLOCKING-BACKGROUND-SAVE — Features FEAT-NON-BLOCKING-BACKGROUND-SAVE
- CON-NON-BLOCKING-BACKGROUND-SAVE-RECOVERY — Non-blocking background save recovery (recovery) — Owner OWN-NON-BLOCKING-BACKGROUND-SAVE — Features FEAT-NON-BLOCKING-BACKGROUND-SAVE
- CON-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-INTERFACE — Fuzzy search across the open workspace interface (interface) — Owner OWN-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — Features FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE
- CON-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-RECOVERY — Fuzzy search across the open workspace recovery (recovery) — Owner OWN-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — Features FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE
- CON-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-INTERFACE — Settings window for typography and keybindings interface (interface) — Owner OWN-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — Features FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS
- CON-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-RECOVERY — Settings window for typography and keybindings recovery (recovery) — Owner OWN-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — Features FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS
- CON-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-INTERFACE — Persist typography and keybindings in UserDefaults interface (interface) — Owner OWN-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — Features FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS
- CON-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-RECOVERY — Persist typography and keybindings in UserDefaults recovery (recovery) — Owner OWN-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — Features FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS
- CON-COLD-LAUNCH-UNDER-100MS-INTERFACE — Cold launch under 100ms interface (interface) — Owner OWN-COLD-LAUNCH-UNDER-100MS — Features FEAT-COLD-LAUNCH-UNDER-100MS
- CON-COLD-LAUNCH-UNDER-100MS-RECOVERY — Cold launch under 100ms recovery (recovery) — Owner OWN-COLD-LAUNCH-UNDER-100MS — Features FEAT-COLD-LAUNCH-UNDER-100MS
- CON-KEYSTROKE-RENDERING-UNDER-16MS-INTERFACE — Keystroke rendering under 16ms interface (interface) — Owner OWN-KEYSTROKE-RENDERING-UNDER-16MS — Features FEAT-KEYSTROKE-RENDERING-UNDER-16MS
- CON-KEYSTROKE-RENDERING-UNDER-16MS-RECOVERY — Keystroke rendering under 16ms recovery (recovery) — Owner OWN-KEYSTROKE-RENDERING-UNDER-16MS — Features FEAT-KEYSTROKE-RENDERING-UNDER-16MS
- CON-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-INTERFACE — Open and save panels for local filesystem access interface (interface) — Owner OWN-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — Features FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
- CON-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-RECOVERY — Open and save panels for local filesystem access recovery (recovery) — Owner OWN-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — Features FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
- CON-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-INTERFACE — Dark monochromatic window appearance interface (interface) — Owner OWN-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — Features FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE
- CON-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-RECOVERY — Dark monochromatic window appearance recovery (recovery) — Owner OWN-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — Features FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE
- CON-DATA-NOTE-FILE — Note file (data) — Owner OWN-DATA-STORE — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE, FEAT-EXPLICIT-SAVE-WITH-CMD-S, FEAT-NON-BLOCKING-BACKGROUND-SAVE, FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE, FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
- CON-DATA-OPEN-DOCUMENT-BUFFER — Open document buffer (data) — Owner OWN-DATA-STORE — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE, FEAT-NON-BLOCKING-BACKGROUND-SAVE, FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE, FEAT-KEYSTROKE-RENDERING-UNDER-16MS
- CON-DATA-TEMPORARY-SAVE-FILE — Temporary save file (data) — Owner OWN-DATA-STORE — Features FEAT-EXPLICIT-SAVE-WITH-CMD-S, FEAT-NON-BLOCKING-BACKGROUND-SAVE, FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
- CON-DATA-TYPOGRAPHY-SETTINGS — Typography settings (data) — Owner OWN-DATA-STORE — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE, FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS, FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS, FEAT-COLD-LAUNCH-UNDER-100MS, FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE
- CON-DATA-KEYBINDING-SETTINGS — Keybinding settings (data) — Owner OWN-DATA-STORE — Features FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS, FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS, FEAT-COLD-LAUNCH-UNDER-100MS
- CON-DATA-WORKSPACE-FOLDER-REFERENCE — Workspace folder reference (data) — Owner OWN-DATA-STORE — Features FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE
- CON-LIFECYCLE-APPLICATION-LAUNCH — Application launch (lifecycle) — Owner OWN-LIFECYCLE-COORDINATOR — Features none
- CON-LIFECYCLE-APPLICATION-TERMINATION — Application termination (lifecycle) — Owner OWN-LIFECYCLE-COORDINATOR — Features none
- CON-LIFECYCLE-PRESET — Native macOS SwiftUI Desktop lifecycle (lifecycle) — Owner OWN-LIFECYCLE-COORDINATOR — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE, FEAT-EXPLICIT-SAVE-WITH-CMD-S, FEAT-NON-BLOCKING-BACKGROUND-SAVE, FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE, FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS, FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS, FEAT-COLD-LAUNCH-UNDER-100MS, FEAT-KEYSTROKE-RENDERING-UNDER-16MS, FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS, FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE
- CON-PERSISTENCE-NOTE-FILE — Note file persistence (persistence) — Owner OWN-DATA-STORE — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE, FEAT-EXPLICIT-SAVE-WITH-CMD-S, FEAT-NON-BLOCKING-BACKGROUND-SAVE, FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE, FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
- CON-PERSISTENCE-OPEN-DOCUMENT-BUFFER — Open document buffer persistence (persistence) — Owner OWN-DATA-STORE — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE, FEAT-NON-BLOCKING-BACKGROUND-SAVE, FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE, FEAT-KEYSTROKE-RENDERING-UNDER-16MS
- CON-PERSISTENCE-TEMPORARY-SAVE-FILE — Temporary save file persistence (persistence) — Owner OWN-DATA-STORE — Features FEAT-EXPLICIT-SAVE-WITH-CMD-S, FEAT-NON-BLOCKING-BACKGROUND-SAVE, FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
- CON-PERSISTENCE-TYPOGRAPHY-SETTINGS — Typography settings persistence (persistence) — Owner OWN-DATA-STORE — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE, FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS, FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS, FEAT-COLD-LAUNCH-UNDER-100MS, FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE
- CON-PERSISTENCE-KEYBINDING-SETTINGS — Keybinding settings persistence (persistence) — Owner OWN-DATA-STORE — Features FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS, FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS, FEAT-COLD-LAUNCH-UNDER-100MS
- CON-PERSISTENCE-WORKSPACE-FOLDER-REFERENCE — Workspace folder reference persistence (persistence) — Owner OWN-DATA-STORE — Features FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE
- CON-PERMISSION-FILESYSTEM — filesystem permission (permission) — Owner OWN-PERMISSION-COORDINATOR — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE, FEAT-EXPLICIT-SAVE-WITH-CMD-S, FEAT-NON-BLOCKING-BACKGROUND-SAVE, FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE, FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
- CON-SECURITY-BOUNDARY — Privacy and security boundary (security) — Owner OWN-PACKAGING — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE, FEAT-EXPLICIT-SAVE-WITH-CMD-S, FEAT-NON-BLOCKING-BACKGROUND-SAVE, FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE, FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS, FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS, FEAT-COLD-LAUNCH-UNDER-100MS, FEAT-KEYSTROKE-RENDERING-UNDER-16MS, FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS, FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE
- CON-PACKAGING-RELEASE — Native macOS SwiftUI Desktop packaging (packaging) — Owner OWN-PACKAGING — Features FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE, FEAT-EXPLICIT-SAVE-WITH-CMD-S, FEAT-NON-BLOCKING-BACKGROUND-SAVE, FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE, FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS, FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS, FEAT-COLD-LAUNCH-UNDER-100MS, FEAT-KEYSTROKE-RENDERING-UNDER-16MS, FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS, FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE
