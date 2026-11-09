# Local search qualification

November 3, 2026. This records local source verification of the metadata catalog/search and automatic-update implementation. No real R2 credentials, personal inventory, cloud mutations, production deployment or installed-app replacement were used.

## Implemented scope

- A destination-bound private SQLite catalog, exact-byte object identity, local FTS5 token-prefix filename/path search, extension and minimum-size filters.
- Read-only signed R2 inventory transport with opaque pagination, bounded XML/HTTP handling, no redirects/proxies, and metadata-only requests.
- Atomic object/FTS/page-token commits, interrupted-listing resume, fresh generations, targeted missing-object confirmation, mass-disappearance protection, low-space stop and storage identity checks.
- A native Search Drive window, dashboard/menu access and app-local Command–Shift–F shortcut, explicit coverage/freshness, pause/refresh, and safe Finder open/reveal gating.

Automatic verified-upload hints, a bounded authenticated worker feed, targeted subtree reconciliation and scheduled full scans are implemented. A hierarchical app folder browser, arbitrary substring/full-text/semantic search, annotations and Finder metadata acceleration remain later roadmap work. See [automatic updates](AUTOMATIC_INDEX_UPDATES.md).

## Automated evidence

The final complete Swift suite passed **249 tests with zero failures**, including native Finder/recovery fixtures, upload regressions, catalog/inventory/presentation tests and concurrent search-panel work present in the shared tree. The focused automatic-update/catalog/inventory/direct-upload run passed **91 tests with zero failures**; the final catalog/bulk-deletion/native-eject run passed **42 tests with zero failures**. All **21 Python signing/configuration tests** also passed.

The catalog tests exercise persistent offline restore; token resume across reopening; transactional rollback after a second-row SQL failure; repeated tokens; generation supersession; destination mismatch and exclusive locking; byte-distinct Unicode/case variants; unsafe mount keys; invalid-page rejection; literal query handling; cancellation; database/directory replacement; corruption; low space; safe deletion and resurrection; and mass-disappearance protection.

The controller tests prove offline restore/search never constructs a remote, destination switches clear results, late old-destination inventory cannot populate the new catalog, and the latest query's error/results win. An isolated NSHostingView/NSWindow rendering test uses synthetic metadata, no Keychain and no mount/worker. Its PNG was inspected for field/table/button layout; this is not a complete accessibility audit or a physical keyboard/open-file end-to-end test.

The wire fixture verifies SigV4 independently using Python hashlib/hmac, including opaque continuation tokens and Unicode/percent/plus keys. Request accounting proves a complete initial fixture scan performs only two bucket LIST GETs and that subsequent searches add no requests. HEAD tests prove 403 and redirects do not mean missing, and signed redirects are not followed. Production transport rejects non-R2 endpoints before sending. Parser tests cover 0/1,000/1,001 records, malformed/truncated XML, embedded errors, duplicate fields, invalid numeric/date/encoding/scope values, entities and response size limits.

Existing multipart transport tests passed after factoring out the shared signer. Native Finder lifecycle/recovery tests passed in the complete suite using isolated synthetic fixtures. The new native mutation test copied a real file through the NFS mount, renamed it, deleted it and renamed a directory, then observed automatic search changes without calling catalog Refresh. Ordinary file operations did not cause another root inventory scan. A final copy immediately followed by Eject was also indexed automatically, exercising capture of publications that finish while the normal event poll is stopped for draining. An invalid control token could not read the metadata feed.

## Scale measurements

Reference machine: Apple Silicon Mac16,7, 24 GiB RAM; macOS 27.2 build 26B123; linked SQLite 3.54.0; Swift debug build. Generated paths use 97 project folders, tokenized filenames and fixed synthetic validators. Sixty sequential warm queries cover common filename prefixes, path-only prefixes, token matches, no matches and a multi-term query.

| Objects | Metadata page insertion time | Query p95 | Query maximum |
| --- | --- | --- | --- |
| 100,000 | 4.718 seconds | 1.842 ms | 1.962 ms |
| 1,000,000 | 62.773 seconds | 12.478 ms | 13.293 ms |

These are local SQL/store measurements. They exclude R2 request time, UI debounce/rendering, cold-cache effects and system Spotlight/Finder behavior. The insertion workload searches between page commits, but does not benchmark every production reconciliation/progress step. They are evidence of useful local-query scaling, not a claim of those latencies on every Mac, every query/filter distribution, or a million-object network inventory completing in one minute.

An earlier scoring-based query measured about 70 ms p95 at 100,000 objects. The shipped query uses bounded filename-first/token-prefix passes in row-ID order instead of scoring every matching object. This sacrifices global relevance ranking for bounded interactive retrieval. Search has a cooperative 150 ms execution deadline and a 45 ms UI debounce; it reports refinement errors when work exceeds the budget.

Cold launch, p95 keystroke-to-render latency, peak RSS, battery/thermal behavior, sustained power-loss injection and real R2 compatibility remain unqualified. Automatic checks add metadata traffic; warm-query measurements remain local-only. The macOS deployment target is still 14; only this host OS/SQLite combination was executed. Runtime feature/schema failures preserve the catalog rather than enabling unsupported fallback behavior.

## Worker and recovery qualification

The pinned backend was rebuilt as `v1.75.2-clouddrive.2`. Metadata feed retention/session/paging/response-size/concurrent-access tests passed. Upstream VFS file/directory rename and removal tests plus feed tests passed under Go's race detector. Allocation/NFS tests passed against the patched backend; no installed worker was replaced.

Catalog v1 migration, legacy upload backfill, durable history-clear delivery, receipt/outbox and feed-cursor rollback, stale reply/deletion-version races, retry fairness, automatic outside-client reconciliation and expired-token restart were checked with synthetic fixtures. Bulk outside deletion automatically required a second identical complete inventory and 200 independent absence checks. Intervening mutations invalidated the bulk confirmation.

## Builds and source checks

The regenerated Xcode project built and packaged a local ad-hoc preview successfully using separate `build/CatalogVerification` derived data. SwiftPM compiled the same new sources and tests. No application was installed or connected to a real destination. The final Xcode build/package passed with the regenerated project and qualified backend. Patch hashes and reapplication against the verified upstream archive reproduced the qualified Go sources. The backend/corresponding-source manifest hashes matched, and the vendored rebuild script uses the pinned backend version. Python syntax, whitespace and local documentation link checks passed.

## Reproduce

```sh
swift test --filter 'Catalog|Inventory|MultipartTransport'
CLOUDDRIVE_CATALOG_SCALE=100000 swift test --filter CatalogTests.testScaleQueriesAndOfflineRestore
CLOUDDRIVE_CATALOG_SCALE=1000000 swift test --filter CatalogTests.testScaleQueriesAndOfflineRestore
swift test
python3 scripts/generate-xcode-project.py
xcodebuild -project CloudDrive.xcodeproj -scheme CloudDrive -configuration Debug -derivedDataPath build/CatalogVerification CLOUDDRIVE_ADHOC_ONLY=1 build
```

See [usage and limitations](LOCAL_SEARCH.md) and [the remaining implementation roadmap](LOCAL_INDEX_AND_SEARCH_IMPLEMENTATION_GUIDE.md).
