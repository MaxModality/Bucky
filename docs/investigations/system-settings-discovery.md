# Missing System Settings results

Investigation date: 2026-10-15. Observed system: macOS 27.0.1, build 26A434.

## Finding

Bucky's System Settings discovery assumes one internal sidebar filename and one
plist schema. Both assumptions fail on the inspected OS. It also intentionally
limits discovery to sidebar entries, excluding separately launchable pages hosted
inside General, including Login Items.

This is a discovery compatibility issue. The inspected extensions still advertise
support for System Settings URLs. The evidence does not establish that Apple is
trying to prevent third-party launchers from opening these pages.

The investigation initially reproduced this issue in version 3.1.6. The branch now
implements the compatibility fix in version 3.1.7: scan immediate `Sidebar*.plist`
resources, merge supported section keys, and traverse eligible installed hosted
extensions with duplicate/cycle protection. Sidebar metadata is still required;
if none is readable, no Settings destinations are emitted. Discovery does not
enumerate actual login items, background services, or their configuration. A Login
Items result opens that page through its extension URL.

## Evidence from the installed OS

`SystemSettingsIndexer` defaults to:

```text
/System/Applications/System Settings.app/Contents/Resources/Sidebar.plist
```

That file is absent. The resources directory instead contains `Sidebar124.plist`.
Its sections contain `ordered_content` and `sortable_content`; the indexer reads
only `content`. Merely changing the filename would therefore still produce zero
results. The numeric filename is an observed implementation detail, not a stable
API or a recommended new hardcoded dependency.

`load()` returns immediately if its sidebar bundle ID list is empty, before
scanning either configured extension directory. A small standalone probe compiled
with the unmodified production `SystemSettingsIndexer.swift` returned:

```text
Production SystemSettingsIndexer result count: 0
DisplaysExt: Displays
Wallpaper: Wallpaper
SecurityPrivacyExtension: Privacy & Security
LoginItems: Login Items
```

The four names were read through Foundation's `Bundle` localized info lookup. All
four extensions have
`EXAppExtensionAttributes.SettingsExtensionAttributes.allowsXAppleSystemPreferencesURLScheme`
set to `true` in their installed `Contents/Info.plist` files.

| Requested entry | Installed extension bundle ID | In the inspected sidebar? |
| --- | --- | --- |
| Displays | `com.apple.Displays-Settings.extension` | Yes, `sortable_content` |
| Wallpaper | `com.apple.Wallpaper-Settings.extension` | Yes, `sortable_content` |
| Privacy & Security | `com.apple.settings.PrivacySecurity.extension` | Yes, `ordered_content` |
| Login Items | `com.apple.LoginItems-Settings.extension` | No; hosted under General |

The extensions reside under `/System/Library/ExtensionKit/Extensions`, which Bucky
already scans. General's `com.apple.systempreferences.GeneralSettings` extension
lists Login Items in its `SettingsExtensionAttributes.hosted_bundles`, alongside
Software Update, Storage, Language & Region, Date & Time, Sharing, Time Machine,
and other pages. Reading only sidebar entries excludes these even with a working
sidebar parser.

An independent metadata scan found 51 URL-enabled extension bundle IDs across
Bucky's two configured roots, with 36 exact matches among 39 sidebar identifiers.
These are metadata counts, not a verified count of pages available on every Mac.
Some entries have hardware/account predicates, aliases, or scene-qualified IDs.
One unrelated plist could not be parsed by Python's plist reader and was skipped;
the four extensions above were readable. The production zero-result probe uses
Foundation and does not depend on that Python scan.

## Integration and test review

- `ApplicationIndexer.load()` appends the settings provider's results before
  sorting. The general `.app` bundle scan cannot discover individual Settings
  pages because these are extensions, not standalone applications.
- Startup and Command+R perform fresh background indexing; the snapshot cache is
  replaced by fresh results. Reindexing repeats the broken discovery logic, so it
  cannot recover the entries by itself.
- The source stream already watches System Settings resources and both extension
  roots. The watcher is not the cause.
- The existing discovery tests create the old `Sidebar.plist`/`content` shape.
  They do not cover an absent sidebar or the observed replacement schema.
- An existing test explicitly excludes fine-grained `.searchTerms` sections. Login
  Items is a separate installed extension, so adding it need not require parsing
  arbitrary search terms or inventing subsection URLs.

All three existing `SystemSettingsIndexerTests` passed during this investigation,
despite the live zero-result reproduction. The build also reported existing
implicit strong-capture and non-Sendable snapshot-cache capture warnings in
`LiquidGlassLauncherModel`. These warnings are separate from the parser failure;
the finite background indexing closures do not by themselves establish a leak.

## Repair design and remaining considerations

1. Keep the existing bounded immediate-child extension scan and require explicit
   URL-scheme opt-in. Skip missing or malformed sidebar resources individually so
   another matching file can supply the catalog.
2. Scan `Sidebar*.plist` without relying on one numeric filename. Merge the three
   supported section keys, preserve compatibility with the old shape, and
   deduplicate bundle IDs. A future unknown schema still requires a parser update.
3. Include independently launchable hosted extensions such as Login Items. Define
   a clear policy for conditionally available hardware/account panes; blindly
   listing every eligible extension can expose entries unavailable on this Mac.
   Do not execute metadata predicates or load extension code to discover names.
4. Keep localized bundle names and the fixed `x-apple.systempreferences:` launch
   scheme. Restrict launch identifiers to valid bundle/scene identifiers before
   constructing URLs. Treat aliases and scenes deliberately rather than guessing
   arbitrary deep links.
5. Add regressions for missing/malformed sidebar metadata, both sidebar schemas,
   hosted Login Items, duplicates, and extensions without URL-scheme opt-in. Keep
   the existing boundary against arbitrary `.searchTerms` subsection entries.
6. Verify navigation on supported macOS versions. The patch version is now 3.1.7;
   the snapshot format remains unchanged, so no snapshot schema bump is needed.

## Security, resources, and limits

The reviewed discovery path reads local bundle metadata and constructs URLs; it
does not execute shell commands, load extension executables, or make network
requests. It owns no persistent tasks, observers, or caches, and no obvious retain
cycle was found in this path. This was a code review, not a process-level leak
measurement. Existing background indexing and Skeleton loading can remain intact.
A repair should preserve bounded scans and avoid logging personal settings data.
There are no remote API calls in this path that need retry/backoff.

After the fix, the same production-indexer probe returned 49 destinations on the
inspected OS, including Displays, Wallpaper, Privacy & Security, and Login Items
with their expected extension URLs. All 19 focused tests passed across settings
discovery, application indexing, snapshot persistence, and source-stream policy.
The seven settings tests cover wildcard filenames, supported keys, duplicate and
cyclic references, malformed files, hosted-page eligibility, and URL-component
injection rejection. Bundle metadata passed `plutil -lint`, and `git diff --check`
reported no whitespace errors.

The investigation did not open the four destination panes or verify end-to-end
navigation. URL opt-in proves discoverable metadata, not that every destination
works on every supported OS. Sidebar filenames and Settings-specific extension
attributes should be treated as internal implementation details.

## Apple sources

- [Apple's device-management schema](https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.systempreferences.yaml)
  lists Settings extension identifiers including Displays, Wallpaper, and Login
  Items. This documents identifiers for management, not a launcher discovery API.
- [SMAppService.openSystemSettingsLoginItems()](https://developer.apple.com/documentation/servicemanagement/smappservice/opensystemsettingsloginitems())
  is a public API that opens the Login Items control panel. Its existence is
  evidence that programmatic access to this page is supported.
- [Login Items & Extensions settings](https://support.apple.com/guide/mac-help/mtusr003/mac)
  documents the page under General.

Apple's public material supports programmatic access and the extension-based
structure. It does not promise stability for Bucky's sidebar parsing strategy or
establish a motive for internal metadata changes.

## Countdowns integration check

The compatibility review compared this fix with `agent/countdowns` at commit
`a579189`, version 3.2.17. Its working tree was clean and was not modified.

The settings implementation and tests merge cleanly with that branch. An isolated
archive of Countdowns with these two files applied passed all 21 focused tests
across settings discovery, application indexing, snapshot persistence, and source
stream policy. README changes use the same build prerequisites as Countdowns and
place the Settings documentation outside its edited sections; README and
`.gitignore` merge cleanly as well.

For the standalone PR to `master`, 3.1.7 is a patch release after 3.1.6. It does not
replace or consume the Countdowns 3.2.17 version. A future merge of the complete
branches has two expected textual conflicts: `packaging/Info.plist` and
`CHANGELOG.md`. Resolve the plist by retaining the higher Countdowns version (or
its then-current newer version), and keep both changelog histories, placing 3.1.7
between the 3.2.x entries and 3.1.6. Never resolve the version to 3.1.7 after
Countdowns is integrated. If the fix is shipped as a new release on top of 3.2.17,
the appropriate new patch version is 3.2.18 instead.

This check is against the recorded Countdowns commit; continued development can
change the integration result and should be checked again before merge.
