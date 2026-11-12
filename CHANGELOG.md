# Changelog

All notable changes to Bucky are documented here.

Development version accounting was corrected on 2026-11-11. Intermediate changes had incorrectly retained 3.3.1 or 3.4.0, and the first version correction stamped 3.4.1. The entries from 3.3.1 through 3.4.5 below now assign each development step its own version retrospectively; they do not imply published releases or historical builds for every number. Each subsequent implementation or correction step must increment the bundle version.

## [3.4.5] - 2026-11-11

### Corrected

- Account for every implementation iteration and version correction separately, documenting the previously omitted bumps and updating the bundle version to match.

## [3.4.4] - 2026-11-11

### Corrected

- Make the first explicit version correction after the Strange alignment. That correction originally stamped 3.4.1; this entry records its own place in the reconciled iteration sequence.

## [3.4.3] - 2026-11-11

### Fixed

- Align launch-on-startup with Strange: allow registration when no login-item record exists, open Login Items for approval, show approval as a separate state, and refresh after returning from System Settings.
- Add three focused service regression tests and verify the controller in Swift 6 language mode.

## [3.4.2] - 2026-11-11

### Fixed

- Treat a missing login item as already off when reading its status or disabling startup, removing the erroneous missing-item alert for the off action.

## [3.4.1] - 2026-11-11

### Fixed

- Read launch-on-startup state from macOS instead of saved JSON and remove the settings-file write that blocked the toggle before Service Management ran.

## [3.4.0] - 2026-11-11

### Added

- Show the installed Bucky version at the bottom of the menu bar menu.

## [3.3.2] - 2026-11-11

### Fixed

- Handle unknown future Service Management status values so the startup controller's switch is exhaustive in Swift 6.

## [3.3.1] - 2026-11-11

### Fixed

- Skip duplicate registration and unregistration based on macOS status, allowing a stale startup preference to be cleared after the login item was removed.
- Place the changes in the Countdown worktree and remove the accidental edits from master.

## [3.3.0] - 2026-10-16

### Added

- Add Never, Daily, Weekdays, Weekly, Monthly, and Yearly repeat choices to Countdown creation and saved-row menus.
- Derive the next occurrence from the original date and saved time zone, skip missed occurrences and invalid month dates, and preserve existing one-time countdown files.
- Queue the next 60 upcoming notification occurrences across countdowns, refilling on launch, edits, and hourly while running. Closed-app alerts stop when the queue is exhausted until Bucky runs again.

### Improved

- Keep recurring time updates local to visible row text and plan notifications off the UI executor.
- Serialize notification updates with stale-generation checks and bounded backoff for transient scheduling failures.

## [3.2.18] - 2026-10-15

### Fixed

- Integrate the System Settings discovery fix from 3.1.7: scan `Sidebar*.plist`, support current and legacy section keys, and include hosted destination pages such as Login Items without reading configured apps or services.

## [3.2.17] - 2026-10-06

### Improved

- Reverse an in-progress launcher close into an opening animation when the global hotkey is pressed again.

## [3.2.16] - 2026-10-06

### Improved

- Add opt-in visibility timing events to diagnose hotkey close and reopen latency.

## [3.2.15] - 2026-10-06

### Fixed

- Restore focus to the active input after switching Stones.
- Publish completed deferred Dictionary snapshots so lookup results replace the loading state.

## [3.2.14] - 2026-10-05

### Improved

- Add a red Confirm Deletion button to Countdown confirmation prompts while keeping Return as the default confirmation key.

## [3.2.13] - 2026-10-05

### Fixed

- Make the Countdown plus button submit reliably across its full 36-point hit area, with Return handling scoped to the title field.

## [3.2.12] - 2026-10-05

### Added

- Schedule a native macOS notification when a saved countdown reaches its target, including when Bucky is closed. Ask for notification permission when the first countdown is created, and keep scheduled notifications in sync with countdown creation and deletion.

## [3.2.11] - 2026-10-05

### Fixed

- Give the shared results scroll viewport a constant 1% input surface so row gaps and padding receive scrolling over another window. Keep the native window backing clear and the prepared glass backdrop unchanged.
- Convert AppKit hit-test points from the superview before checking the hosting view's bounds, including offset and flipped hosts.
- Check native window targeting against a synthetic window underneath, in addition to in-app scroll hit testing.

### Verification

- Reproduce gap wheel events reaching an underlying scroll window with a fully transparent viewport in a real application run loop. With the viewport fill, verify downward/upward gap scrolling, inset scrolling, and eight repeated stationary-cursor wheel inputs without any event reaching the underlying window.
- Add three coordinate regressions that fail with the previous hosting-view fallback and pass with the correction.

## [3.2.10] - 2026-10-03

### Fixed

- Keep the launcher glass backdrop prepared with the hidden Apps shell so opening has no delayed opaque-to-transparent flash. Reduce Transparency uses a stable opaque surface.
- Define rectangular interaction shapes for results and row gaps. This addressed in-app hit testing but did not resolve scrolling through to an underlying window.

## [3.2.9] - 2026-10-03

### Improved

- Reveal the prepared SwiftUI Apps shell immediately at full opacity, preserve its input/list across hides, and remove the extra hotkey actor hop and queued focus reset.
- Let Liquid Glass settle in on an independent background after input idle; defer cold app-icon work so input and filtering get priority.
- Cache app result rows and compact revisions, prepare row/title ranks away from the UI executor, start typing searches directly from the native SwiftUI binding without debounce, and cooperatively cancel obsolete search work.
- Warm only missing deletion-prefix searches after input idle, with no hidden-window warming.
- Rasterize icons at display size, reduce cache budgets to 8/16 MiB, purge on memory pressure, and limit preload batches to 32 entries.
- Share SwiftUI icon loading, remove unused Files icon observers, and reuse content/sidebar revisions instead of rebuilding path identities.

### Verification

- Add native input/readiness and teardown coverage, cancellation/ranking/race tests, icon memory-bound tests, and a live-filter regression gate.
- Add opt-in timing diagnostics containing fixed stage names and elapsed milliseconds only.
- Allow the existing Files test helpers in optimized test builds.

## [3.2.8] - 2026-10-01

### Fixed

- Preserve saved configuration and Countdown records on failed reads or writes; reject new Countdowns at capacity instead of evicting existing records.
- Keep Files operations off the UI thread, prevent Keep Both destination races from replacing files, and suspend inactive directory work.
- Cancel obsolete directory and preview jobs, bound preview concurrency and retained navigation state, and skip unreadable children without losing readable siblings.
- Bound calculator input and recursion, and avoid integer formatting overflow.
- Use typed exclusions for custom actions and watch explicitly included apps and missing source roots.
- Bind confirmation actions to their originating Stone and block background interaction until dismissed.
- Restrict persisted files to private permissions and avoid logging private paths, commands, or URLs in diagnostics.
- Preserve tags and release assets on failure, verify signed tags and packages before publication, and retry API reads with bounded backoff.

### Changed

- Route Calculator history and async Stone actions through shared provider contracts and consolidate launcher shortcut decoding.
- Precompute app search metadata, generation-scope deferred filters, and replace recurring cache warming with bounded event-driven work.
- Update Countdown time text independently of stable rows, without fades or hidden/expired clock work.
- Save settings and history asynchronously, surface failures, and drain Files operations and queued persistence on normal quit.
- Package incrementally without cleaning shared build output, and isolate test data from normal app configuration.

## [3.2.7] - 2026-10-01

### Fixed

- Added native Cut, Copy, Paste, and Select All commands for focused input boxes throughout the app.

## [3.2.6] - 2026-09-03

### Fixed

- Focus the Countdown title field after the inline creation row finishes mounting during keyboard mode switches.

## [3.2.5] - 2026-09-03

### Fixed

- Reused the Files-style Liquid Glass confirmation overlay for Countdown deletion instead of opening a separate AppKit modal.
- Focus the Countdown title field when the stone opens and handle Return from any creation-row field.
- Refuse empty Countdown titles with a subtle red underline on the title field.

## [3.2.4] - 2026-09-02

### Changed

- Replaced the Countdown add/edit modal with an always-visible inline creation row containing native glass date and time fields.
- Press Return in the name field or the plus button to create a countdown immediately below the creation row.

## [3.2.3] - 2026-09-02

### Fixed

- Focus the Countdown name field immediately when the editor opens.
- Pass all keyboard input through to active Countdown modals so shifted text, Tab navigation, and date-picker arrow keys are handled by the modal.

## [3.2.2] - 2026-09-02

### Fixed

- Keep Countdown modal interactions visible while focus is temporarily lost, then restore launcher focus after the modal closes.
- Give Countdown editor controls stable spacing and enough room for date selection.
- Remove live result transition animation from Countdown updates so displayed time changes frame by frame.

## [3.2.1] - 2026-09-02

### Fixed

- Made the menubar icon size and visibility explicit so it remains visible across macOS menu bar layouts.

## [3.2.0] - 2026-09-01

### Added

- Added the green Countdowns Stone with named target datetimes, live remaining-time display, and add/edit/delete management.
- Added atomic JSON persistence for countdowns and generic Stone provider actions plus live refresh metadata.

## [3.1.7] - 2026-10-15

### Fixed

- System Settings discovery now scans `Sidebar*.plist` resources and supports legacy and current sidebar section keys.
- Independently launchable settings pages hosted inside General, including Login Items, now appear as destinations without reading their configured apps or services.
- Duplicate and cyclic hosted-page references are resolved once, and malformed sidebar files are skipped.

## [3.1.6] - 2026-09-01

### Added

- Reusable Stone provider contracts, catalog metadata, shared result snapshots, row actions, and activation handling for future Stones.
- Shared animated skeleton loading states across launcher results, file browsing, and native previews.

### Improved

- Dictionary lookups and application icon loading now have bounded, cancellable, stale-result-safe execution paths.
- File preview loading now shows consistent loading feedback before native content is ready.
- Release tooling no longer fetches and rewrites existing historical tags during release preparation.

### Cleaned up

- Removed unused ranking seams, obsolete UI transition policy code, tautological tests, and non-neutral test fixture data from repository history.
- Updated architecture documentation with the extension recipe for adding a new Stone without duplicating launcher behavior or UI conventions.
