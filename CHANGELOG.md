# Changelog

All notable changes to Bucky are documented here.

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
