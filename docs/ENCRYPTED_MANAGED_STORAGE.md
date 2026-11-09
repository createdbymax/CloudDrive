# Encrypted managed storage

Implementation specification, 2026-11-05. This is an opt-in **remote-storage encryption** layer for a newly created managed volume. Compatible bucket mode and existing plaintext namespace formats are not silently converted. Local staging, range cache, SQLite metadata and recovery journals remain protected by local file permissions and OS disk encryption; this feature does not encrypt those local files.

## Data flow

`NamespaceOwner → SyncEngine / ManagedManifestPublisher → EncryptedStorageRemote → S3StorageRemote`.

The decorator encrypts file payloads, trie pages, commits and HEAD. Visible filenames and namespace JSON are inside authenticated ciphertext. Provider credentials remain necessary to access the bucket. The provider can still observe object paths containing opaque IDs, timing, request ranges, encoded lengths, and operation metadata. This format does not hide sizes or provide global rollback protection against a malicious provider replaying an old valid HEAD.

`EncryptedDriveKey.generate()` produces a random 256-bit master key. `EncryptedDriveKey.identifier(for:)` is its SHA-256 identity. Engine config carries `encryptionKeyBase64` and `encryptionKeyID` through its existing private stdin configuration path, not command-line arguments. The local checked `encryption.json` marker binds namespace storage to the chosen key ID and connection binding. Missing or mismatched keys fail startup; the engine does not try plaintext fallback. New encrypted creation checks for an empty remote prefix and no existing local Namespace. Explicit encrypted remote recovery is a separate route.

## Object format version 1

All integers are unsigned, big endian. Header length is 104 bytes; chunk payload size is 1,048,576 bytes.

| Offset | Length | Meaning |
|---|---:|---|
| 0 | 8 | ASCII `CDENC001` |
| 8 | 4 | Chunk size |
| 12 | 4 | Format version 1 |
| 16 | 8 | Logical plaintext size |
| 24 | 32 | Random per-object salt |
| 56 | 32 | SHA-256 of original logical object key |
| 88 | 16 | AES-GCM authentication tag for the header |
| 104 onward | variable | Ordered ciphertext chunks, each followed by a 16-byte authentication tag |

HKDF-SHA256 derives a 256-bit object key from the master key and salt with domain `CloudDrive encrypted object v1`. Header authentication seals empty plaintext with nonce zero and the first 88 header bytes as AAD. Chunk nonce is four zero bytes followed by the 64-bit chunk index plus one. Chunk AAD binds the first 88 header bytes, chunk index and plaintext chunk length. The original content object key includes its node/generation/operation identity. Random per-object subkeys keep nonce spaces separate.

Encoded size is `104 + logicalSize + 16 * ceil(logicalSize / 1MiB)` (zero chunks for an empty file). Header validation precedes any returned logical size. Every range read fetches and authenticates complete intersecting chunks; the decorator validates underlying range offsets, total size and provider validator. It returns only requested plaintext bytes and never labels a ciphertext checksum as a plaintext checksum.

The current format accepts logical sizes up to 600,000,000,000 bytes; provider and local workload gates can impose smaller practical limits. This numerical bound is overflow/format admission, not a qualified performance guarantee.

## Multipart retry and physical keys

S3 multipart completion may publish to a fresh opaque content key. Changing that transport behavior could weaken lost-completion recovery. Instead the decorator returns a virtual backing locator:

`<prefix>/.clouddrive/v1/content/.encrypted/<base64url logical-key digest>/<base64url physical-key suffix>`.

Encrypted namespace metadata authenticates this locator. Reads resolve the physical suffix and require its authenticated header to match the expected logical-key digest. Moving ciphertext between different logical identities fails authentication. Direct metadata objects retain their actual key as the authenticated context.

Before upload, a private durable encryption intent records key identity, logical key, size and random salt. Each chunk's plaintext digest is persisted **before** using its nonce. A repeatable multipart reader returns identical ciphertext for arbitrary repeated part boundaries. Reusing the same operation with different plaintext fails before encrypting the changed chunk, preventing nonce reuse across retries. These intent/digest files must be retained with multipart journals until a future coordinated garbage-collection protocol proves them unnecessary. The implementation currently retains them rather than guessing that cleanup is safe.

## Recovery envelope

`EncryptedDriveRecoveryEnvelope.create(masterKey:keyID:)` returns a Codable versioned envelope and a separately generated 256-bit recovery secret encoded in base64. HKDF-SHA256 (`CloudDrive recovery envelope v1`) derives the wrapping key; AES-GCM encrypts the master key and binds envelope version/key ID in AAD. `recover(recoveryKey:)` authenticates and verifies the recovered master-key identity.

The recovery secret is random key material, **not a human password**. No password-strength claim or password KDF is implied. Envelope and recovery secret together are sufficient to recover the drive key; keep the recovery secret private. Loss of both the Keychain master key and valid recovery material prevents decryption.

## Deliberate boundaries

- Ordinary-key server-side copy/export and modification through the encrypted decorator return unsupported. A future decrypted export must explicitly write to a separate plaintext destination and report that change to the user.
- Import accepts an empty remote prefix only. There is no in-place plaintext migration.
- Encryption does not alter managed HEAD compare-and-swap behavior or convert the drive into a collaborative multi-writer system.
- Key rotation, secure deletion of local plaintext, remote journal garbage collection, and a security review of the new format remain separate work. No claim of an independently audited cryptosystem or production qualification is made.

## Verification

`Tests/CloudDriveCoreTests/EncryptedStorageTests.swift` covers envelope recovery/wrong-secret/tamper, random physical key locators, cross-chunk ranged reads, repeated multipart boundaries, wrong key, ciphertext transplant/corruption, CAS preservation, changed retry rejection, persistent encryption mode guards, and full managed publish/recovery/decryption. Local synthetic evidence does not replace isolated-provider, interrupted-process, large-file and security qualification.

The implementation uses Apple's authenticated [AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm) and [HKDF](https://developer.apple.com/documentation/cryptokit/hkdf) primitives. Format and retry protocols above are BucketDrive's own implementation decisions.
