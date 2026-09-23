# Product Requirements Document — Monospace Notes

## Document Purpose

Define the product boundary, users, problems, goals, journeys, feature outcomes, success criteria, and explicit scope without implementation invention.

## Product Definition

A native macOS document editor for a single person working in a local folder of plain-text notes. The window uses a black background (#000000) with high-contrast monospace type. Editing is handled by TextKit 2 with keystroke rendering under 16ms, cold launch under 100ms, and fuzzy search across the open workspace under 50ms. Each note is one .txt file. Saves are explicit with Cmd+S and also run as non-blocking background writes that replace the destination by renaming a temporary file. A Settings window opened from the macOS menu bar edits typography and keybindings. Notes stay on the local filesystem through open and save panels. Typography and keybindings stay in UserDefaults. The app does not use the network, accounts, or third-party APIs.

## Problem Statement

A single writer who keeps a local folder of plain-text notes needs a focused way to open and edit one .txt note at a time with TextKit 2 rendering without network access, accounts, or third-party APIs.

## Target Users

- A single writer who keeps a local folder of plain-text notes
- A macOS user who prefers keyboard-driven editing over mouse interaction
- A privacy-conscious user who wants notes to remain on the local filesystem
- A user who wants a dark, high-contrast monospace reading and writing surface

## Goals

- Open and edit one .txt note at a time with TextKit 2 rendering
- Keep keystroke rendering under 16ms and cold launch under 100ms
- Run fuzzy search across the open workspace in under 50ms
- Save explicitly with Cmd+S and also persist through non-blocking background writes
- Replace the destination file by renaming a temporary file so partial writes never corrupt a note
- Let the user edit typography and keybindings in a Settings window opened from the macOS menu bar
- Keep notes on the local filesystem through open and save panels
- Store typography and keybindings in UserDefaults

## Non-Goals

- No network access, accounts, or third-party APIs
- No cloud sync or remote storage
- No multi-user collaboration or shared editing
- No rich-text formatting, images, or embedded media
- No plugin or extension system
- No mobile or web client
- No automatic background indexing of folders the user has not opened
- No telemetry or analytics collection

## Primary User Journeys

### Open and edit a plain-text note outcome

- Actor: A single writer who keeps a local folder of plain-text notes
- Steps: The user chooses Open from the File menu or presses Cmd+O and selects a .txt file in the open panel. → The app reads the selected .txt file as UTF-8 text and displays it in a TextKit 2 text view with the configured monospace font and point size. The window title shows the file name. Editing modifies the in-memory text buffer and marks the document as having unsaved changes.
- Outcome: The user can open a .txt file from the local filesystem and edit its contents in a monospace text surface.

### Explicit save with Cmd+S outcome

- Actor: A single writer who keeps a local folder of plain-text notes
- Steps: The user presses Cmd+S while a document is open. → The app writes the current buffer to the document's file path as UTF-8 text. If the document has no path, the app presents a save panel and uses the chosen path. On success, the unsaved-changes marker is cleared. The write replaces the destination by renaming a temporary file in the same directory.
- Outcome: The user can commit the current buffer to disk on demand.

### Non-blocking background save outcome

- Actor: A single writer who keeps a local folder of plain-text notes
- Steps: A save is initiated by Cmd+S or by the background autosave interval of 30000ms after the last edit. → The app writes the buffer to a temporary file in the same directory as the destination, then replaces the destination by renaming the temporary file over it. The write and rename run off the main thread so the text view remains responsive to keystrokes.
- Outcome: The user can keep typing while the document is written to disk.

### Fuzzy search across the open workspace outcome

- Actor: A single writer who keeps a local folder of plain-text notes
- Steps: The user presses Cmd+F and types one or more characters into the search field. → The app matches the query against note file names and note contents in the currently open workspace folder using a fuzzy subsequence match, and lists matching notes ordered by match score. Selecting a result opens that note.
- Outcome: The user can locate a note by typing an approximate name or phrase and see matching results.

### Settings window for typography and keybindings outcome

- Actor: A single writer who keeps a local folder of plain-text notes
- Steps: The user chooses Settings from the macOS menu bar. → The app opens a Settings window with controls for font family, point size, and keybinding assignments. Changes apply to the open document immediately and are written to UserDefaults.
- Outcome: The user can change the monospace font, point size, and keybindings without editing files.

### Persist typography and keybindings in UserDefaults outcome

- Actor: A single writer who keeps a local folder of plain-text notes
- Steps: The app launches or the user changes a typography or keybinding setting. → The app reads typography and keybinding values from UserDefaults at launch and writes them whenever they change. Missing values fall back to the defaults: font family Menlo, point size 13, and Cmd+S for save.
- Outcome: The user's typography and keybinding choices survive app restarts.

### Cold launch under 100ms outcome

- Actor: A single writer who keeps a local folder of plain-text notes
- Steps: The user launches the app from Finder or the Dock. → The app initializes its window, text view, and settings from UserDefaults and presents an editable document window. No network calls or remote resource loads occur during launch.
- Outcome: The user sees an editable window almost immediately after launching the app.

### Keystroke rendering under 16ms outcome

- Actor: A single writer who keeps a local folder of plain-text notes
- Steps: The user presses a character key while the text view has focus. → The app inserts the character into the text buffer and lays out and draws the updated text using TextKit 2. The main thread performs no file I/O during keystroke handling.
- Outcome: The user sees typed characters appear in the text view without perceptible delay.

### Open and save panels for local filesystem access outcome

- Actor: A single writer who keeps a local folder of plain-text notes
- Steps: The user chooses Open or Save As from the File menu. → The app presents the standard macOS open or save panel restricted to .txt files. The chosen path is used for reading or writing the note. The app does not access paths outside the user's selection. The write replaces the destination by renaming a temporary file in the same directory.
- Outcome: The user can choose which local .txt files to open and where to save them.

### Dark monochromatic window appearance outcome

- Actor: A single writer who keeps a local folder of plain-text notes
- Steps: The app window is displayed. → The window background is #000000 and the text is rendered in the configured monospace font at the configured point size with a foreground color that meets a contrast ratio of at least 7:1 against #000000.
- Outcome: The user reads and writes on a black background with high-contrast monospace text.

## Feature Contracts

### FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — Open and edit a plain-text note

- Behavior: The app reads the selected .txt file as UTF-8 text and displays it in a TextKit 2 text view with the configured monospace font and point size. The window title shows the file name. Editing modifies the in-memory text buffer and marks the document as having unsaved changes.
- Inputs: The user chooses Open from the File menu or presses Cmd+O and selects a .txt file in the open panel.
- Outputs: The user can open a .txt file from the local filesystem and edit its contents in a monospace text surface.
- Acceptance outcomes: After a keystroke that changes the buffer, the document is marked as having unsaved changes.; After selecting a readable .txt file, the text view contains exactly the file's UTF-8 decoded contents.; If the file is unreadable, an error alert is presented and the previously open document remains displayed.; The window title equals the selected file's last path component.
- Failure behavior: If the file cannot be read, the app shows an error alert naming the file and the read error, and leaves the current document unchanged.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Open and edit a plain-text note.

### FEAT-EXPLICIT-SAVE-WITH-CMD-S — Explicit save with Cmd+S

- Behavior: The app writes the current buffer to the document's file path as UTF-8 text. If the document has no path, the app presents a save panel and uses the chosen path. On success, the unsaved-changes marker is cleared. The write replaces the destination by renaming a temporary file in the same directory.
- Inputs: The user presses Cmd+S while a document is open.
- Outputs: The user can commit the current buffer to disk on demand.
- Acceptance outcomes: After a successful save, the unsaved-changes marker is cleared.; After Cmd+S on a document with a path, reading that path returns exactly the buffer contents as UTF-8.; After Cmd+S on a document without a path, a save panel is presented before any write occurs.; If the write fails, an error alert is presented and the unsaved-changes marker remains set.
- Failure behavior: If the write fails, the app shows an error alert naming the path and the write error, and the document remains marked as having unsaved changes.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Explicit save with Cmd+S.

### FEAT-NON-BLOCKING-BACKGROUND-SAVE — Non-blocking background save

- Behavior: The app writes the buffer to a temporary file in the same directory as the destination, then replaces the destination by renaming the temporary file over it. The write and rename run off the main thread so the text view remains responsive to keystrokes.
- Inputs: A save is initiated by Cmd+S or by the background autosave interval of 30000ms after the last edit.
- Outputs: The user can keep typing while the document is written to disk.
- Acceptance outcomes: A failed background save produces a visible non-modal status message naming the path.; After a successful background save, the destination file contains exactly the buffer contents and no temporary file remains in the directory.; During a background save, a keystroke entered within 16ms of the save start is reflected in the text view before the save completes.; If the rename fails, the destination file's bytes are unchanged from before the save attempt.
- Failure behavior: If the temporary write or rename fails, the app leaves the destination file unchanged, removes the temporary file when possible, and reports the failure in a non-modal status area.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Non-blocking background save.

### FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — Fuzzy search across the open workspace

- Behavior: The app matches the query against note file names and note contents in the currently open workspace folder using a fuzzy subsequence match, and lists matching notes ordered by match score. Selecting a result opens that note.
- Inputs: The user presses Cmd+F and types one or more characters into the search field.
- Outputs: The user can locate a note by typing an approximate name or phrase and see matching results.
- Acceptance outcomes: A query that is a subsequence of a note's file name includes that note in the results.; A query with no matches shows an empty-state message and does not change the open document.; For a workspace of 500 notes totaling 5MB, a query returns results within 50ms measured from the last keystroke.; Selecting a result opens the corresponding note in the text view.
- Failure behavior: If no note matches, the results list shows an empty-state message and the current document remains open.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Fuzzy search across the open workspace.

### FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — Settings window for typography and keybindings

- Behavior: The app opens a Settings window with controls for font family, point size, and keybinding assignments. Changes apply to the open document immediately and are written to UserDefaults.
- Inputs: The user chooses Settings from the macOS menu bar.
- Outputs: The user can change the monospace font, point size, and keybindings without editing files.
- Acceptance outcomes: After changing a setting, the corresponding UserDefaults key contains the new value.; Choosing a font family and point size updates the text view's font to that family and size.; Choosing an unavailable font family leaves the text view font unchanged and shows an inline message.; Reopening the Settings window shows the previously chosen values.
- Failure behavior: If a chosen font family is unavailable, the app keeps the previous font family and shows an inline message naming the unavailable family.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Settings window for typography and keybindings.

### FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — Persist typography and keybindings in UserDefaults

- Behavior: The app reads typography and keybinding values from UserDefaults at launch and writes them whenever they change. Missing values fall back to the defaults: font family Menlo, point size 13, and Cmd+S for save.
- Inputs: The app launches or the user changes a typography or keybinding setting.
- Outputs: The user's typography and keybinding choices survive app restarts.
- Acceptance outcomes: After changing the point size to 16 and relaunching, the text view uses 16 points.; After changing the save keybinding and relaunching, the new keybinding triggers save.; An invalid stored point size causes the app to use 13 points without failing to launch.; On launch with no stored values, the text view uses Menlo at 13 points.
- Failure behavior: If a stored value is missing or invalid, the app uses the default value for that setting and continues launching.
- Recovery: Apply the stated fallback automatically, keep Persist typography and keybindings in UserDefaults usable, and require no user retry.

### FEAT-COLD-LAUNCH-UNDER-100MS — Cold launch under 100ms

- Behavior: The app initializes its window, text view, and settings from UserDefaults and presents an editable document window. No network calls or remote resource loads occur during launch.
- Inputs: The user launches the app from Finder or the Dock.
- Outputs: The user sees an editable window almost immediately after launching the app.
- Acceptance outcomes: At the moment the window is editable, the text view accepts keystrokes.; If initialization fails, an error alert is presented and no editable window remains.; Measured from process start to the first editable window, cold launch completes in under 100ms on the reference machine.; No network requests are issued during launch.
- Failure behavior: If launch initialization fails, the app presents an error alert and exits without leaving a partially initialized window.
- Recovery: Release partial resources before exiting so a relaunch of Cold launch under 100ms starts from a clean state.

### FEAT-KEYSTROKE-RENDERING-UNDER-16MS — Keystroke rendering under 16ms

- Behavior: The app inserts the character into the text buffer and lays out and draws the updated text using TextKit 2. The main thread performs no file I/O during keystroke handling.
- Inputs: The user presses a character key while the text view has focus.
- Outputs: The user sees typed characters appear in the text view without perceptible delay.
- Acceptance outcomes: A layout failure leaves the text buffer unchanged for that keystroke.; Measured from key event to updated text view drawing, keystroke rendering completes in under 16ms for a 100KB document.; No file read or write occurs on the main thread during keystroke handling.; The inserted character appears in the text buffer immediately after the key event is handled.
- Failure behavior: If layout or drawing fails, the app logs the failure and leaves the text buffer unchanged for that keystroke.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Keystroke rendering under 16ms.

### FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — Open and save panels for local filesystem access

- Behavior: The app presents the standard macOS open or save panel restricted to .txt files. The chosen path is used for reading or writing the note. The app does not access paths outside the user's selection. The write replaces the destination by renaming a temporary file in the same directory.
- Inputs: The user chooses Open or Save As from the File menu.
- Outputs: The user can choose which local .txt files to open and where to save them.
- Acceptance outcomes: After choosing a file in the open panel, the app reads that exact path.; After choosing a path in the save panel, the app writes to that exact path.; Cancelling panel leaves the current document and path unchanged.; The open panel lists only .txt files as selectable.
- Failure behavior: If the user cancels the panel, the app leaves the current document and its path unchanged.
- Recovery: Preserve the last valid state, explain the failure, and allow an explicit retry of Open and save panels for local filesystem access.

### FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — Dark monochromatic window appearance

- Behavior: The window background is #000000 and the text is rendered in the configured monospace font at the configured point size with a foreground color that meets a contrast ratio of at least 7:1 against #000000.
- Inputs: The app window is displayed.
- Outputs: The user reads and writes on a black background with high-contrast monospace text.
- Acceptance outcomes: If the configured foreground color fails the contrast check, the rendered foreground color passes it.; The text foreground color has a contrast ratio of at least 7:1 against #000000.; The text view uses the configured monospace font family and point size.; The window background color equals #000000.
- Failure behavior: If the configured foreground color does not meet the contrast ratio, the app substitutes a foreground color that does.
- Recovery: Apply the stated fallback automatically, keep Dark monochromatic window appearance usable, and require no user retry.

## Requirement Contracts

- REQ-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — The app reads the selected .txt file as UTF-8 text and displays it in a TextKit 2 text view with the configured monospace font and point size. The window title shows the file name. Editing modifies the in-memory text buffer and marks the document as having unsaved changes. Acceptance ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-01, ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-02, ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-03, ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-04: After a keystroke that changes the buffer, the document is marked as having unsaved changes.; After selecting a readable .txt file, the text view contains exactly the file's UTF-8 decoded contents.; If the file is unreadable, an error alert is presented and the previously open document remains displayed.; The window title equals the selected file's last path component.
- REQ-EXPLICIT-SAVE-WITH-CMD-S — The app writes the current buffer to the document's file path as UTF-8 text. If the document has no path, the app presents a save panel and uses the chosen path. On success, the unsaved-changes marker is cleared. The write replaces the destination by renaming a temporary file in the same directory. Acceptance ACC-EXPLICIT-SAVE-WITH-CMD-S-01, ACC-EXPLICIT-SAVE-WITH-CMD-S-02, ACC-EXPLICIT-SAVE-WITH-CMD-S-03, ACC-EXPLICIT-SAVE-WITH-CMD-S-04: After a successful save, the unsaved-changes marker is cleared.; After Cmd+S on a document with a path, reading that path returns exactly the buffer contents as UTF-8.; After Cmd+S on a document without a path, a save panel is presented before any write occurs.; If the write fails, an error alert is presented and the unsaved-changes marker remains set.
- REQ-NON-BLOCKING-BACKGROUND-SAVE — The app writes the buffer to a temporary file in the same directory as the destination, then replaces the destination by renaming the temporary file over it. The write and rename run off the main thread so the text view remains responsive to keystrokes. Acceptance ACC-NON-BLOCKING-BACKGROUND-SAVE-01, ACC-NON-BLOCKING-BACKGROUND-SAVE-02, ACC-NON-BLOCKING-BACKGROUND-SAVE-03, ACC-NON-BLOCKING-BACKGROUND-SAVE-04: A failed background save produces a visible non-modal status message naming the path.; After a successful background save, the destination file contains exactly the buffer contents and no temporary file remains in the directory.; During a background save, a keystroke entered within 16ms of the save start is reflected in the text view before the save completes.; If the rename fails, the destination file's bytes are unchanged from before the save attempt.
- REQ-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — The app matches the query against note file names and note contents in the currently open workspace folder using a fuzzy subsequence match, and lists matching notes ordered by match score. Selecting a result opens that note. Acceptance ACC-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-01, ACC-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-02, ACC-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-03, ACC-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-04: A query that is a subsequence of a note's file name includes that note in the results.; A query with no matches shows an empty-state message and does not change the open document.; For a workspace of 500 notes totaling 5MB, a query returns results within 50ms measured from the last keystroke.; Selecting a result opens the corresponding note in the text view.
- REQ-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — The app opens a Settings window with controls for font family, point size, and keybinding assignments. Changes apply to the open document immediately and are written to UserDefaults. Acceptance ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-01, ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-02, ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-03, ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-04: After changing a setting, the corresponding UserDefaults key contains the new value.; Choosing a font family and point size updates the text view's font to that family and size.; Choosing an unavailable font family leaves the text view font unchanged and shows an inline message.; Reopening the Settings window shows the previously chosen values.
- REQ-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — The app reads typography and keybinding values from UserDefaults at launch and writes them whenever they change. Missing values fall back to the defaults: font family Menlo, point size 13, and Cmd+S for save. Acceptance ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-01, ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-02, ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-03, ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-04: After changing the point size to 16 and relaunching, the text view uses 16 points.; After changing the save keybinding and relaunching, the new keybinding triggers save.; An invalid stored point size causes the app to use 13 points without failing to launch.; On launch with no stored values, the text view uses Menlo at 13 points.
- REQ-COLD-LAUNCH-UNDER-100MS — The app initializes its window, text view, and settings from UserDefaults and presents an editable document window. No network calls or remote resource loads occur during launch. Acceptance ACC-COLD-LAUNCH-UNDER-100MS-01, ACC-COLD-LAUNCH-UNDER-100MS-02, ACC-COLD-LAUNCH-UNDER-100MS-03, ACC-COLD-LAUNCH-UNDER-100MS-04: At the moment the window is editable, the text view accepts keystrokes.; If initialization fails, an error alert is presented and no editable window remains.; Measured from process start to the first editable window, cold launch completes in under 100ms on the reference machine.; No network requests are issued during launch.
- REQ-KEYSTROKE-RENDERING-UNDER-16MS — The app inserts the character into the text buffer and lays out and draws the updated text using TextKit 2. The main thread performs no file I/O during keystroke handling. Acceptance ACC-KEYSTROKE-RENDERING-UNDER-16MS-01, ACC-KEYSTROKE-RENDERING-UNDER-16MS-02, ACC-KEYSTROKE-RENDERING-UNDER-16MS-03, ACC-KEYSTROKE-RENDERING-UNDER-16MS-04: A layout failure leaves the text buffer unchanged for that keystroke.; Measured from key event to updated text view drawing, keystroke rendering completes in under 16ms for a 100KB document.; No file read or write occurs on the main thread during keystroke handling.; The inserted character appears in the text buffer immediately after the key event is handled.
- REQ-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — The app presents the standard macOS open or save panel restricted to .txt files. The chosen path is used for reading or writing the note. The app does not access paths outside the user's selection. The write replaces the destination by renaming a temporary file in the same directory. Acceptance ACC-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-01, ACC-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-02, ACC-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-03, ACC-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-04: After choosing a file in the open panel, the app reads that exact path.; After choosing a path in the save panel, the app writes to that exact path.; Cancelling panel leaves the current document and path unchanged.; The open panel lists only .txt files as selectable.
- REQ-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — The window background is #000000 and the text is rendered in the configured monospace font at the configured point size with a foreground color that meets a contrast ratio of at least 7:1 against #000000. Acceptance ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-01, ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-02, ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-03, ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-04: If the configured foreground color fails the contrast check, the rendered foreground color passes it.; The text foreground color has a contrast ratio of at least 7:1 against #000000.; The text view uses the configured monospace font family and point size.; The window background color equals #000000.

## Shared End-to-End Acceptance

- No shared acceptance criterion requires the final integration and packaging gate.

## UX Requirements

- Keystroke rendering completes in under 16ms for a 100KB document.
- Cold launch completes in under 100ms from process start to first editable window.
- Fuzzy search over a 500-note, 5MB workspace returns results within 50ms of the last keystroke.
- Background saves do not block the main thread and do not delay keystroke handling.
- Destination files are replaced by renaming a temporary file so a failed save never leaves a partially written note.
- Window background is #000000 and text foreground contrast against it is at least 7:1.
- Typography and keybindings persist across launches through UserDefaults.
- The app performs no network requests at any time.

## Privacy and Security Requirements

- Minimize collected data and keep it inside the preset-defined owner, storage, and integration boundaries.
- Protect Note file as personal data and never expose it through logs or diagnostics.
- Protect Open document buffer as personal data and never expose it through logs or diagnostics.
- Protect Temporary save file as personal data and never expose it through logs or diagnostics.
- Protect Typography settings as internal data and never expose it through logs or diagnostics.
- Protect Keybinding settings as internal data and never expose it through logs or diagnostics.
- Protect Workspace folder reference as internal data and never expose it through logs or diagnostics.

## Operational Constraints

- Runs only on macOS as a native application.
- Each note is exactly one .txt file encoded as UTF-8.
- Notes are accessed only through the local filesystem via open and save panels.
- Typography and keybindings are stored only in UserDefaults.
- No network access, accounts, or third-party APIs are used.
- The window uses a #000000 background with high-contrast monospace type.
- Editing uses TextKit 2.
- Saves are explicit with Cmd+S and also run as non-blocking background writes.

## Success Criteria

- Open and edit one .txt note at a time with TextKit 2 rendering
- Keep keystroke rendering under 16ms and cold launch under 100ms
- Run fuzzy search across the open workspace in under 50ms
- Save explicitly with Cmd+S and also persist through non-blocking background writes
- Replace the destination file by renaming a temporary file so partial writes never corrupt a note
- Let the user edit typography and keybindings in a Settings window opened from the macOS menu bar
- Keep notes on the local filesystem through open and save panels
- Store typography and keybindings in UserDefaults
- After selecting a readable .txt file, the text view contains exactly the file's UTF-8 decoded contents.
- The window title equals the selected file's last path component.
- After a keystroke that changes the buffer, the document is marked as having unsaved changes.
- If the file is unreadable, an error alert is presented and the previously open document remains displayed.
- After Cmd+S on a document with a path, reading that path returns exactly the buffer contents as UTF-8.
- After a successful save, the unsaved-changes marker is cleared.
- After Cmd+S on a document without a path, a save panel is presented before any write occurs.
- If the write fails, an error alert is presented and the unsaved-changes marker remains set.
- During a background save, a keystroke entered within 16ms of the save start is reflected in the text view before the save completes.
- After a successful background save, the destination file contains exactly the buffer contents and no temporary file remains in the directory.
- If the rename fails, the destination file's bytes are unchanged from before the save attempt.
- A failed background save produces a visible non-modal status message naming the path.
- For a workspace of 500 notes totaling 5MB, a query returns results within 50ms measured from the last keystroke.
- A query that is a subsequence of a note's file name includes that note in the results.
- Selecting a result opens the corresponding note in the text view.
- A query with no matches shows an empty-state message and does not change the open document.
- Choosing a font family and point size updates the text view's font to that family and size.
- After changing a setting, the corresponding UserDefaults key contains the new value.
- Reopening the Settings window shows the previously chosen values.
- Choosing an unavailable font family leaves the text view font unchanged and shows an inline message.
- On launch with no stored values, the text view uses Menlo at 13 points.
- After changing the point size to 16 and relaunching, the text view uses 16 points.
- After changing the save keybinding and relaunching, the new keybinding triggers save.
- An invalid stored point size causes the app to use 13 points without failing to launch.
- Measured from process start to the first editable window, cold launch completes in under 100ms on the reference machine.
- At the moment the window is editable, the text view accepts keystrokes.
- No network requests are issued during launch.
- If initialization fails, an error alert is presented and no editable window remains.
- Measured from key event to updated text view drawing, keystroke rendering completes in under 16ms for a 100KB document.
- The inserted character appears in the text buffer immediately after the key event is handled.
- No file read or write occurs on the main thread during keystroke handling.
- A layout failure leaves the text buffer unchanged for that keystroke.
- The open panel lists only .txt files as selectable.
- After choosing a file in the open panel, the app reads that exact path.
- After choosing a path in the save panel, the app writes to that exact path.
- Cancelling panel leaves the current document and path unchanged.
- The window background color equals #000000.
- The text foreground color has a contrast ratio of at least 7:1 against #000000.
- The text view uses the configured monospace font family and point size.
- If the configured foreground color fails the contrast check, the rendered foreground color passes it.

## Explicit Assumptions

- The selected preset is authoritative for every technology and mechanical decision.
- Omitted mechanics use the conservative preset-defined contract without another provider request.

## Scope Boundaries

- Included features: Open and edit a plain-text note; Explicit save with Cmd+S; Non-blocking background save; Fuzzy search across the open workspace; Settings window for typography and keybindings; Persist typography and keybindings in UserDefaults; Cold launch under 100ms; Keystroke rendering under 16ms; Open and save panels for local filesystem access; Dark monochromatic window appearance
- Excluded outcomes: No network access, accounts, or third-party APIs; No cloud sync or remote storage; No multi-user collaboration or shared editing; No rich-text formatting, images, or embedded media; No plugin or extension system; No mobile or web client; No automatic background indexing of folders the user has not opened; No telemetry or analytics collection
- Locked delivery preset: native-macos-swiftui-desktop

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
