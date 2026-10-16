# File storage — V1 specification

## Concept

- Google Drive-like file storage. V1 is personal external storage; sharing between users comes in V2.
- **The server is the single source of truth.** Web, Android and desktop show the same state. No local folder synchronization.
- Open sign-up, LAN access only.
- Quota: **50 GB per user**. The trash and the space reserved by ongoing uploads count toward the quota.

## Model

- Folders and files are database rows. Each one knows its parent's id (`parent_id`); the displayed path is built by walking up the parents.
- **Flat** physical storage: `<storage directory>/<uuid>`, no extension.
  - The storage directory comes from configuration (a Docker volume mounted on a fixed path, e.g. `/data/files`). The database only stores the UUID.
  - Renaming or moving only touches the database; the physical file never moves.
- The **MIME type** is detected from the content (magic bytes) at upload and stored in the database. It is never derived from the file name or from what the client claims.

| Forbidden | Allowed |
|---|---|
| Empty file (0 bytes) | Move |
| File larger than 2 GB | Rename |
| Copying a file | |

## Duplicates

- Fingerprint: **SHA-256** of the content. MD5 and SHA-1 are ruled out: collisions can be crafted on purpose.
- Computed by the client before sending (to avoid useless uploads) and **recomputed by the server** on reception: the client's hash is never trusted.
- Comparison is limited to **the user's own files**: a global comparison would reveal that another user owns a given file.

| Case | Situation | Response |
|---|---|---|
| A | Same name, same content, same folder | "This file is already here" |
| B | Same name, different content | User's choice: `CANCEL` (client side, nothing is sent), `RENAME`, `REPLACE` |
| C | Different name, same content | Rejected: "File X has the same content" |
| — | Same content as a file in the trash | Rejected: "This file is in the trash as X, do you want to restore it?" |

- `RENAME`: the server picks the name, `beach (1).jpg`, then `(2)`, and so on.
- `REPLACE`: the old file is **permanently deleted** (it does not go to the trash). The confirmation dialog must say so clearly.

## Upload

### 1. `check`

Request: `{ parentId, name, size, sha256 }`

The server, in order:

1. checks that folder `parentId` exists and belongs to the user;
2. rejects if `size = 0`, if `size > 2 GB`, or if the remaining quota is lower than `size`;
3. applies the duplicate rules (cases A, B, C, trash);
4. otherwise creates the file row (`PENDING`), reserves the space on disk, charges it to the quota and responds:

```json
{ "fileId": "…", "chunkSize": 10485760, "numberOfChunks": 205 }
```

The folder is identified by its **id**, not its name: a rename during the upload breaks nothing.

### 2. Chunks

The body carries **only the raw bytes** of the chunk; metadata goes in the URL and headers. JSON was ruled out: base64 adds a third to every chunk, on a Wi-Fi link that is already the bottleneck, and forces the Pi to decode a 13 MB string in memory.

```http
PUT /api/files/{fileId}/chunks/{n}
Content-Type: application/octet-stream
Content-Length: <chunk size>
Content-Digest: sha-256=:<base64 SHA-256 of the chunk>:

<raw chunk bytes>
```

- The URL says **where** (which file, which chunk), the headers **describe** (type, fingerprint), the body is **only data**.
- `Content-Digest` (RFC 9530) is the hash of the bytes in this message, i.e. the chunk. `Repr-Digest` would be the hash of the whole file: not used here.
- No `Content-Range`: the server computes the byte offsets from `n`, so the client never sends them.
- `Content-Length` lets the server reject a chunk of the wrong size before reading it.

- Chunk size: **10 MB**. Chunks are numbered from `1` to `numberOfChunks`.
- **Sequential** sending in V1. The protocol allows parallel uploads, to be evaluated with a real benchmark: on a LAN, a single connection already saturates the link.
- `numberOfChunks = ceilDiv(size, chunkSize)` (`Math.ceilDiv` in Java).
- Last chunk size: `size - (numberOfChunks - 1) × chunkSize`. No modulo: it returns 0 when `size` is an exact multiple of `chunkSize`.
- Chunk `n` is written at byte `(n - 1) × chunkSize`: chunks may arrive out of order.
- The server checks each chunk's SHA-256. A corrupted or missing chunk is requested again, **3 attempts at most** per chunk.
- Received chunk numbers are **stored in the database**: a server restart during an upload loses nothing. The server finds missing chunks by difference with `1..numberOfChunks` (counting is not enough: a chunk received twice would hide a missing one).
- Size, chunk count and last-chunk bounds are computed by the server: the client does not send them.

### 3. Completion

Once all chunks are received, the server computes the full SHA-256 (`HASHING`) and compares it to the one from `check` → `RECEIVED` or `CORRUPTED`.

### Abandoned upload

With no news from the client for **1 week**, the file becomes `INCOMPLETE`. The user sees: "File not found, do you want to delete it?". Until deleted, the reserved space still counts toward the quota.

## File states

```
PENDING ──► SENDING ──► HASHING ──► RECEIVED
               │                └─► CORRUPTED ──"Retry"──► SENDING
               └─(1 week without news)─► INCOMPLETE ──"Retry"──► SENDING
```

| State | Meaning |
|---|---|
| `PENDING` | `check` accepted, space reserved, no chunk received |
| `SENDING` | Chunks being received |
| `HASHING` | All chunks received, full hash being verified |
| `RECEIVED` | File complete and verified |
| `CORRUPTED` | Full hash mismatch, or a chunk failed after 3 attempts |
| `INCOMPLETE` | Upload abandoned for 1 week |

UI: a spinner while processing; for a final failure (`CORRUPTED`, `INCOMPLETE`), a cracked-mountain icon as background with a "Retry" button on top, above the file name.

Upload state and trash membership are two separate pieces of information: the trash is not a state.

## Trash

- `purge_date` field: `null` = not in the trash; otherwise the permanent deletion date (moved to trash + **30 days**).
- A scheduled job runs daily at a fixed time and permanently deletes everything matching `purge_date <= today`. The `<=` catches up on missed days (Pi off, power cut).

### Folder moved to the trash

- The folder row is **kept in the database but hidden** from the user. A folder weighs a few bytes and keeps its files' `parent_id` valid.
- Its files appear **one by one** in the trash, with their original path.
- Restoring a file also restores its parent folders.
- The folder row is deleted together with its last file.
- If the user creates a folder with the same name in the same place as a trashed folder, the old one is reused (`purge_date` reset to `null`).

### Restore

- Name already taken in the destination folder: renamed with `(n)`, as for `RENAME`, and the user is told.
- Same content already present outside the trash: restore is **blocked** (case C rule).

## Display and download

- **Preview** only for raster images (png, jpg…), decided from the MIME type detected and stored in the database.
- **Icon** for everything else, **SVG included**: an SVG is XML and can contain `<script>`, executed on the app's origin if the browser renders it.
- Download forced with the `Content-Disposition: attachment` header.

## Out of V1

- Sharing between users.
- Thumbnails (videos included).
- Parallel upload, depending on the benchmark.
