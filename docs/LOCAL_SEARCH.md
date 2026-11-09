# Local metadata indexing and search

Choose **Search Drive…** in the dashboard/menu, or press **Command–Shift–F** while CloudDrive is active. The initial inventory and later changes are indexed automatically once a valid connection is loaded. The search window works with Finder disconnected; **Connect Finder** uses the existing connection/recovery gates when you want to open a result.

Indexing runs in the background using read-only R2 ListObjectsV2 and targeted HEAD requests. It saves exact object keys, display names/paths, extension, logical size, remote LastModified and opaque ETag. It does not download object contents, traverse the mount, write cloud objects or access original upload files. Remote LastModified is not an original creation date.

Search runs entirely against the saved SQLite catalog. It matches words as token prefixes, ignores case/diacritics, searches filenames before paths, and supports extension and minimum 1 GB filters. For example, `voc final` matches `Vócals Final.wav`. Results are capped at 100; narrow the query to see more specific matches. This first version does not implement arbitrary substring, fuzzy, semantic or file-content search.

## Freshness and interruption

The UI shows saved entry count, listing coverage, refresh state and last successful check. **Refresh index** resumes an interrupted paginated listing. **Start fresh scan** discards its continuation token and starts a new generation; existing entries remain searchable. Closing the search window leaves automatic updates running; **Pause indexing** saves progress and pauses updates until resumed. Quitting the app leaves committed pages intact.

A partial scan never removes unseen entries. Only after successful enumeration are missing candidates checked using HEAD; confirmed not-found responses tombstone them locally. Permission failures, redirects, timeouts and invalid responses do not count as absence. A mass-disappearance circuit breaker retains entries after the first pass. Automatic indexing confirms the same absent key set in another complete inventory before checking individual objects. No cloud deletion is performed.

Verified direct uploads and Finder mutations feed a durable metadata change queue. Automatic targeted checks update the catalog; periodic reconciliation covers outside clients, feed gaps and older workers. See [automatic index updates](AUTOMATIC_INDEX_UPDATES.md) for timing, recovery and pause behavior. Outside changes can still race any listing/HEAD observation.

Opening results requires a safely connected Finder drive. Uncached content still requires connectivity. Unsafe object keys such as dot/empty path segments remain searchable but cannot be opened through the mount. Searchability is not a guarantee that content is locally resident. The catalog cannot speed up Finder's own directory requests or enable Finder/Spotlight search by itself.

## Storage and runtime

Private metadata lives in `Application Support/BucketDrive/Catalog/<destination fingerprint>/catalog.sqlite`, separate from payload caches, worker recovery and multipart upload records. The compatibility `BucketDrive` root is intentional. Credential values, source bookmarks and control tokens are not stored in this database. Exact UTF-8 key bytes are unique identity; search normalization never merges case or Unicode-normalization variants.

SQLite operations run on a dedicated serial queue. Each listing page commits object facts, FTS rows and its opaque continuation token together. Search uses FTS5 token-prefix indexes, filename-first bounded candidate passes and cooperative cancellation with a 150 ms execution budget. The UI adds a 45 ms debounce. Expensive searches fail with a refinement prompt rather than silently blocking the main thread or falling back to an unbounded substring scan.

The first implementation uses DELETE journaling, FULL synchronous commits, one connection, no external-content triggers, and no WAL dependency. It therefore avoids requiring newer WAL fixes on the macOS 14 baseline. The linked SQLite must support FTS5 and RETURNING; incompatible schemas/features fail closed with the existing database preserved. The code does not automatically recreate a corrupt catalog.

There is a default approximately 4 GiB SQLite page limit (at a 4 KiB page size) and a 256 MiB available-space reserve before committing inventory pages. This is a stop condition rather than a total disk quota: rollback journals and filesystem overhead also consume space. Owner locks, private file checks and directory/database identity checks reject concurrent owners and replaced storage. A storage failure does not alter upload receipts or dirty payloads.

## Development and qualification

```sh
swift test --filter 'Catalog|Inventory'
CLOUDDRIVE_CATALOG_SCALE=100000 swift test --filter CatalogTests.testScaleQueriesAndOfflineRestore
CLOUDDRIVE_CATALOG_SCALE=1000000 swift test --filter CatalogTests.testScaleQueriesAndOfflineRestore
swift test
python3 scripts/generate-xcode-project.py
xcodebuild -project CloudDrive.xcodeproj -scheme CloudDrive -configuration Debug -derivedDataPath build/CatalogVerification CLOUDDRIVE_ADHOC_ONLY=1 build
```

The scale test generates deterministic synthetic metadata, commits pages, searches between commits, and reports query distributions. The transport fixture binds only loopback and verifies SigV4 independently in Python; tests need no provider credentials. The offline controller test uses a remote factory that fails if instantiated. The native rendering test creates an isolated SwiftUI search window without a mount, worker or Keychain access. Set `CLOUDDRIVE_SEARCH_SNAPSHOT` to an absolute PNG path to save that test's synthetic rendering.

See [implementation and research roadmap](LOCAL_INDEX_AND_SEARCH_IMPLEMENTATION_GUIDE.md) for later folder browsing, backend metadata acceleration, durable annotations, enrichment and Spotlight work. See [qualification results](LOCAL_SEARCH_VERIFICATION.md) for the actual checks and limits of this implementation.
