# Bucky

The no-frills/robust approach to macOS Launchers.

## Purpose And Architecture

Bucky is a local macOS launcher with Apps, Calculator, Dictionary, Files, and a green Countdowns Stone. SwiftUI owns the search input, focus, result list, and persistent Liquid Glass decoration. The Apps shell stays mounted while hidden. AppKit is confined to the existing menu bar, global hotkey/window host, native services, and responder-chain integration. Stone providers supply metadata, stable result rows, and activation intents through shared contracts. Indexing, configuration saves, Files operations, and previews use background workers so the UI remains responsive, with skeleton loading surfaces during asynchronous handoff.

## Build

Requires macOS 26 or later and an Xcode installation with the macOS 26 SDK and Swift tools compatible with `Package.swift` (Swift 5.9 or later). Select Xcode's developer tools before building; no third-party package installation is required.

```sh
make bundle
```

The app bundle is created at `build/Bucky.app`.

## Run

```sh
open build/Bucky.app
```

## Distribution

For a local distributable archive, run the package script. It builds incrementally without cleaning shared build output, verifies the bundle signature and version, packages only the `.app` bundle, and writes a zip plus SHA-256 checksum under `dist/`. Existing assets are never overwritten; use a new version or explicitly choose a separate output directory with `BUCKY_PACKAGE_DIST_DIR`.

```sh
./package.sh
```

The generated archive uses this naming pattern:

```text
dist/Bucky-<semantic-version>-macos-<architecture>.zip
```

Verify the archive against its adjacent `.sha256` file before opening it. Extract into a fresh directory, then open the contained app. To install, quit any running Bucky instance and use Finder to move the app into Applications; review any replacement prompt yourself.

Local bundles are ad-hoc signed by default, not Developer ID signed or notarized. For broad distribution outside your own machine, configure a suitable signing identity and notarize the app before sharing it.

`./release.sh --dry-run` performs read-only source/ref checks. Publishing with `./release.sh` requires `GITHUB_TOKEN`, a clean default-branch checkout matching the remote, strict semantic versioning, and a valid signed annotated tag (or the ability to create one). Required isolated tests, build, signature, archive-content, and checksum gates run before a tag is pushed or a release is published. API reads use bounded exponential backoff and honor rate-limit pauses; ambiguous writes are reconciled by reads instead of being blindly repeated. Existing tags, draft releases, and assets remain intact on failure for manual review. There is no automatic remote deletion or test-gate bypass.

## Verification

```sh
make test
make tooling-test
```

`make test` isolates app configuration in a new temporary directory unless `BUCKY_DATA_DIRECTORY` is explicitly set to an absolute test directory. The temporary data is retained for diagnosis. `make tooling-test` runs offline mocked packaging/release tests; it does not publish to GitHub. For direct Swift test runs, isolate data explicitly:

```sh
testDataDirectory="$(mktemp -d)"
BUCKY_DATA_DIRECTORY="$testDataDirectory" swift test
```

The launcher performance test keeps the checked-in legacy workload baseline and also gates the live row-ID filter on that same workload with ranking-parity checks. Do not refresh the baseline merely to pass a regression. `make perf` runs optimized filtering and native input-readiness tests with isolated data. Native tests send key events through the real SwiftUI text field, verify the query and filtered rows, and report first/repeated-open timings; their broad timing ceiling accommodates loaded test hosts. Run native UI tests in a desktop session with permission to acquire key windows; a sandbox that denies GUI process registration cannot exercise native input readiness.

```sh
make perf
```

For a real hotkey timing trace, start the built executable with `BUCKY_PERFORMANCE_TRACE=1` and inspect the `local.bucky.performance` subsystem in Console or the `Launcher input readiness` interval in Instruments. The trace records only fixed stage names and monotonic milliseconds. Input-readiness stages cover hotkey/presentation start, visible window, focus request, first nonempty input accepted, and first subsequent filter publication. Visibility events cover hotkey receipt, toggle handling, show start, panel ordering, hide start, animation completion, and hidden cleanup completion. Compare event timestamps to see time spent in the hide animation, hidden cleanup, and the subsequent show call. Focus request is a request, not proof that the native editor has acquired focus; native tests check the actual responder. Timings for physical keyboard delivery and WindowServer rendering require a real app session. Test data and benchmark fixtures are synthetic; queries, app titles, paths, and commands are never logged by this trace.

For scrolling verification, open Bucky above a scrollable window, place the cursor in the gap between two app rows, and scroll both directions. Repeat with the cursor stationary while rows and gaps pass underneath, and over the list inset. Bucky must scroll while the underlying window stays still. Repeat after hiding/reopening; the glass surface must appear immediately without a material transition. Native hit tests cover window/view targeting; this wheel check exercises actual event dispatch.

The [scroll rebound audit](.agents/docs/scroll-rebound-audit.md) records the unresolved change in update cadence after releasing an overscroll, its plain SwiftUI comparison, and the distinction between scroll-offset updates and presentation frame rate.

Use Instruments Allocations/Leaks for process memory and repeated hide/show stress. Unit tests additionally verify controller/cache teardown, canceled searches, memory-pressure cache purging, and bounded icon raster sizes. OS previews, native shortcuts, and locale-dependent date fields still benefit from manual app testing.

## Behavior

Use Option+Space to open or hide the floating launcher by default. Type to filter parsed app names, use the up and down arrows to move through the list, use Command+Up and Command+Down to jump to the top or bottom, and press Return to launch the selected app.

Use `Cmd+1` for Apps, `Cmd+2` for Calculator, `Cmd+3` for Dictionary, `Cmd+4` for Files, and `Cmd+5` for Countdowns while the launcher is open. Use Command+Left and Command+Right to cycle launcher modes, and Command+/ to open shortcut help. Calculator and Dictionary remain separate modes: arithmetic text such as `1` or `2 + 3` is evaluated inline in Calculator without opening Calculator, while Dictionary lookups use fuzzy spelling and completion matches. Press Return on a calculation result to copy it, or on a dictionary result to open Dictionary at the matching word. Calculator mode includes a clear-history button; pin is available from any mode, can be toggled with Command+P while Bucky is focused, and keeps the window above other apps until unpinned.

Files mode shows mounted volumes alongside folders and files, and supports folders-first sorting when you want directories grouped ahead of other entries. Confirmed file mutations run on a serial background worker with a busy skeleton. Keep Both never replaces an existing destination; only explicit Replace permits replacement. Directory requests coalesce and previews cancel obsolete work. The Files watcher suspends when the Stone is inactive. Normal quit drains approved operations and queued preference saves; forcibly terminating the process cannot provide that guarantee.

Countdowns mode stores named target datetimes in `~/Library/Application Support/Bucky/countdowns.json`. The top row accepts a countdown name plus native date and time fields; press Return from the title field or click the plus button to create it, and use a countdown's trash button to open the deletion prompt. Press Return or choose the red Confirm Deletion button; Escape cancels. Empty titles are refused with a red underline and accessible hint. Each countdown displays its remaining days, hours, minutes, seconds, and milliseconds. macOS schedules a native notification for each countdown, including while Bucky is closed; notification permission is requested when the first countdown is created. Only visible remaining-time text ticks, without fades, and expired countdowns freeze at zero. New entries are refused at 100 rather than removing existing entries; legacy files above that limit are preserved.

Bucky uses SwiftUI Liquid Glass as a separate, noninteractive backdrop prepared with the retained hidden Apps shell. Opening shows the same glass surface immediately, without an opaque-to-transparent transition. Reduce Transparency uses a stable opaque surface. The backdrop never controls window opacity, input focus, or list geometry. The results scroll viewport has a constant 1% input surface to keep scrolling over gaps and padding inside Bucky; rectangular interaction shapes handle routing within the list. The native window backing stays clear. Cold icon misses and optional preloads also wait briefly, while cached icons are available immediately. Settings, Help, and heavier Stones retain their normal mount/unmount lifecycle. macOS 26 is required; the previous AppKit launcher has been removed.

App indexing starts during launcher controller initialization and stays fresh through the source stream, settings changes, and explicit refresh paths. Opening the launcher reveals the prepared SwiftUI Apps shell at full opacity and claims focus immediately; while the launcher is open, Command+R reindexes and refreshes the currently displayed results using the current search text. Command+Comma opens Settings.

Focused input boxes support native macOS text editing: Command+X cuts, Command+C copies, Command+V pastes, and Command+A selects all. This includes launcher search, Countdown titles, Settings fields, and Files rename inputs. A shared AppKit Edit menu routes these commands through the responder chain to the focused control; Stones do not implement their own text clipboard handling.

The menu bar item provides Open, Reindex, Settings, and Quit actions. Bucky scans `.app` bundles recursively under `/Applications`, `/System/Applications`, and `~/Applications`, and scans only direct child `.app` bundles under `/System/Library/CoreServices` so native utilities such as Finder stay launchable without walking nested support trees.

System Settings discovery scans `Sidebar*.plist` resources, reads both legacy and
current section keys, and follows installed extensions hosted by sidebar pages.
Each result opens a settings destination, including Login Items; discovery does
not read the apps or services configured on that page. Only installed extensions
that explicitly allow System Settings URLs become results.
The [missing Settings entries investigation](docs/investigations/system-settings-discovery.md)
records the filename/schema compatibility break observed on macOS 27.0.1 and its
repair. Sidebar and hosted-page metadata remain Apple implementation details.

App indexing and mode handoff stay asynchronous. Apps and text Stones show a shared animated Skeleton surface with an accessible loading label while background work is still populating the first result set. Switching into Files first shows the same loading surface until the file browser model is activated, then the file browser publishes its own loading, empty, or loaded directory state.

## Stone Boundaries

Built-in launcher mode metadata lives in `StoneCatalog`, while `StoneProvider` is the generic extension boundary registered through `StoneProviderRegistry`. `TextStoneProvider` remains a source-compatible name for existing conformers. Shared rows flow through `StoneResultRow` and `StoneResultSnapshot`, and shared side effects flow through `StoneActivation` plus `LiquidGlassLauncherModel.perform(_:,for:)`. That keeps mode definitions, result rendering, and activation behavior aligned across built-in and extension Stones.

To add a new Stone:

- Define a provider-owned `StoneDefinition`, conform to `StoneProvider`, and register through `StoneProviderRegistry`; the provider owns its `StoneID`, metadata, query behavior, and activation mapping.
- Choose `.textInput` for a query-driven Stone or `.sharedResults` for a non-input Stone that uses the common result list and generic active mode pill.
- Use the registry-backed launcher mode and shortcut collections so the new Stone appears in ordering, keyboard navigation, placeholders, icons, surfaces, tints, and update policy without editing a central enum or switch.
- Keep Stone-specific query/result behavior in a focused Stone helper or boundary, then map its output into shared `StoneResultRow` and `StoneResultSnapshot` values. `.fileBrowser` is reserved for the built-in Files mode; the registry ignores providers that claim that surface or the built-in Files identity, so they cannot bypass provider routing.
- Reuse shared activation intents where possible and extend `StoneActivation` only if the new Stone needs a genuinely new cross-cutting side effect. Use generic accessory presentation defaults or set a row's `accessoryPresentation` for a domain-specific symbol or help string; do not add Stone cases to the launcher view.
- Use async provider activations for disk-backed work. `HistoryStoneProvider` exposes shared history/clear behavior; Calculator owns its debounce and history shaping instead of duplicating them in the launcher. Named-datetime creation uses the shared inline creation contract, while confirmations block the background surface and remain bound to the originating Stone.
- Add focused coverage in `Tests/BuckyTests/StoneCatalogTests.swift`, `Tests/BuckyTests/LauncherModeRoutingTests.swift`, `Tests/BuckyTests/StoneResultsTests.swift`, plus Stone-specific behavior tests for the new domain.
- Keep domain-specific rules inside the new Stone instead of widening shared launcher policy.

## Settings

Settings are stored as JSON at:

```text
~/Library/Application Support/Bucky/settings.json
```

Settings currently include the global hotkey, launch-on-startup preference, and animation timing preference.

Calculation history is stored as JSON at:

```text
~/Library/Application Support/Bucky/calculations.json
```

## Inclusions

Included app paths are stored as JSON at:

```text
~/Library/Application Support/Bucky/inclusions.json
```

The file format is:

```json
{
  "includedPaths": [
    "/System/Library/CoreServices/Finder.app"
  ]
}
```

Use Settings to add apps through the macOS file picker or remove included apps from the list.

If `inclusions.json` is missing, Bucky creates it with an empty `includedPaths` array. Malformed or unreadable files are preserved; Bucky keeps its last valid in-memory configuration (or an empty initial default), displays an error, and refuses changes until a successful reload. Explicitly included app parent directories are watched for changes, including existing ancestors of missing roots. Finder is discovered by the direct `/System/Library/CoreServices` scan, not injected through this file.

## Exclusions

Each result has a hide button. Exclusions are stored as JSON at:

```text
~/Library/Application Support/Bucky/exclusions.json
```

The file format is:

```json
{
  "excludedPaths": [
    "/Applications/Example.app"
  ]
}
```

Edit that file manually and press Command+R in Bucky to reload it, or remove hidden apps from Settings.

Missing exclusions initialize an empty set. Malformed or unreadable exclusions preserve the last valid state and block writes until a successful reload. New exclusions also carry typed identities for application paths, launch URLs, and stable custom-action IDs; legacy `excludedPaths` entries remain readable. An empty legacy path no longer hides every custom action.

## Persistence And Privacy

Configuration and history stores share a serial JSON worker. Runtime settings and history changes save asynchronously and publish success only after persistence; failures retain drafts and previous data and display controlled diagnostics. JSON replacement is atomic, uses `0600` files and `0700` newly created directories, and does not alter existing ancestor permissions. Reads reject symlinks and nonregular files and are bounded to 8 MiB; Countdowns additionally limits its input file to 128 KiB. Invalid files are not silently repaired or replaced.

Files preferences use a coalescing background writer and optimistic UI updates with error reporting and latest-state rollback. Traversal history is bounded to 128, remembered selections and ordinary bookmarks to 256, and new pins to 128; existing pins and their access bookmarks are protected rather than silently deleted. Icon caches store display-sized rasters with 8 MiB Apps and 16 MiB Files cost budgets and purge warm entries on system memory pressure. Optional preloads are limited to 32 entries; Files follows the selection viewport. Hidden Apps icon tasks cancel, while Files and preview UI unmount. The native SwiftUI text binding starts search immediately, without waiting for a render-driven change callback. Search runs on a serial Swift actor, cooperatively cancels obsolete scans and sorts, and starts new queries without an artificial typing debounce. Missing deletion-prefix cache entries warm only after 250 ms of input idle time. App row/title-rank preparation runs off the UI executor; snapshots are reused until data or result IDs change. Text previews allow at most two active reads with a 64 KiB limit and reject pipes/devices. Cancellation suppresses obsolete results but cannot forcibly interrupt a filesystem call already executing.

Diagnostics avoid recording app paths, launch URLs, shell commands, or file contents. Configuration is local JSON with private permissions, not encrypted secret storage; do not save credentials in custom-action commands. Custom actions are explicitly user-configured local shell commands, not a sandbox for untrusted scripts. Review commands before saving them. See [.agents/docs/bucky-architecture.md](.agents/docs/bucky-architecture.md) for implementation boundaries.

## Fixture And PII Rules

Committed fixtures, screenshots, and JSON examples must stay neutral. Use placeholders such as `/Users/test`, `/Applications/Example.app`, and sample names already used in tests. Do not commit company names, customer names, private domains, or other non-public identifiers in docs, fixtures, or example config.
