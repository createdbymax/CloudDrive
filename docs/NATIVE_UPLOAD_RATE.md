# Native upload rate control

`UploadBandwidthLimiter` and `BandwidthLimitedStorageRemote` apply a shared outgoing request-body budget to the namespace engine. The engine wraps the S3/fixture transport **before encryption**, so encrypted uploads charge encoded ciphertext bytes, including authentication overhead. The cap applies across concurrent managed preparation lanes and metadata PUTs rather than giving each upload its own full allowance.

The rate is bytes per second; zero means unlimited. `configureUploadRate` uses `NamespaceRPCRequest.offset` for this value. The owner persists the selected value in its checked sync-control state, restores it when starting, and exposes `uploadRateBytesPerSecond` in status. The app's fixed upload speed setting can configure the same engine policy. Reads, HEAD requests, listings, provider-side copies and conditional deletion are uncapped by this upload budget.

## Precise enforcement boundary

This is a FIFO token budget controlling admission of outgoing request bodies. It does not pace individual URLSession socket writes. The provider transport builds a bounded multipart part before sending it, so the wire can burst by a part (maximum 64 MiB). Aggregate admitted bytes are bounded by the configured rate plus at most that retained burst budget. A newly changed rate starts with zero accumulated credit. Already admitted network requests can finish at their existing transfer speed; a new rate changes queued and subsequent admissions.

Repeated upload-reader requests are charged again. This is conservative when the transport rereads a part without transmitting it; the limiter never guesses which bytes were actually sent. No adaptive congestion management, prioritization over other applications, or instantaneous network-speed guarantee is claimed.

The limiter queues at most 128 requests; each request is at most 64 MiB. Invalid sizes/rates are rejected. Cancellation removes a queued request without reserving future time that would block other uploads. Changing to unlimited immediately wakes queued work. Existing engine pause semantics remain: stop scheduling new work and finish/reconcile admitted work. A paused/pausing large upload may therefore need its currently admitted object to finish under the selected rate; the rate control remains changeable while this happens.

## Verification

`UploadBandwidthTests` uses a manual monotonic clock. Tests verify concurrent requests sharing one FIFO allowance, cancellation freeing the next waiter, dynamic rate changes and unlimited wakeup, bounded idle credit, immediate cancellation, uncapped reads, and compatible-provider qualification through the wrapper. These checks use no multi-second real-time sleeps. Separate real-provider throughput measurement is still necessary to characterize part-sized bursts on a particular connection.

## Managed Finder upload scheduling (November 6, 2026)

The managed sync engine now prepares up to eight immutable file payloads concurrently (configurable from one to eight in the engine initializer). Selection scans the pending batch and fixes each consecutive write run before preparing only its final generation. This includes Finder write runs that previously bypassed parallel preparation. Prepared payloads remain unpublished until their journal dependencies reach the ordered publication frontier. A publication failure, pause, or restart preserves receipts and the fixed run endpoints; preparation does not clear dirty data. Compatible-mode publication is unchanged.

Background passes process up to 128 operations rather than 16 before the existing two-second polling delay. Concurrency is bounded by files; multipart parts within each file remain sequential. Small-file metadata publication remains ordered and can limit throughput independently of available bandwidth. Eight concurrent files do not imply a particular network speed.

Verification: all 170 CloudDriveCoreTests passed locally. The new regression test exercises ten files with four Finder writes each, observes eight simultaneous payload uploads, rejects HEAD publication, reopens the journal, and verifies exact content and reuse of the eight uploaded payloads. The existing window-bound test now covers twelve files and an eight-upload ceiling.
