# Cloud

A self-hosted, Google Drive-like file storage running on a Raspberry Pi 5 at home, built for family use.

One server, three clients:

| App | Stack | Status |
|---|---|---|
| [`server/`](server/) | Java 25, Spring Boot 4, PostgreSQL | In progress |
| `web/` | React | Planned |
| `android/` | Kotlin | Planned |
| `desktop/` | Rust/Tauri or Compose Multiplatform (not decided yet) | Planned |

## How this project is built

I write all the application code myself. I use an AI assistant (Claude) as a guide, not as a code generator: it asks questions, challenges my design choices and reviews what I write. The reasoning behind each decision is recorded in the specs.

Progress is shared on LinkedIn.

## Features (V1)

- Accounts with open sign-up, 50 GB quota per user.
- Folders, upload, download, rename, move.
- Duplicate detection based on SHA-256 content hashes.
- Resumable chunked upload (10 MB chunks, per-chunk integrity check), up to 2 GB per file.
- Trash with automatic permanent deletion after 30 days.
- Image previews.

The server is the single source of truth: every client shows the same state, no local folder sync. Access is limited to the local network.

Planned for V2: sharing between users, thumbnails, parallel upload.

## Architecture

```
        ┌──────────┐  ┌───────────┐  ┌───────────┐
        │  Web app │  │  Android  │  │  Desktop  │
        └────┬─────┘  └─────┬─────┘  └─────┬─────┘
             └──────────────┼──────────────┘
                            │ HTTP API (LAN)
                 ┌──────────▼──────────┐
                 │  Raspberry Pi 5     │
                 │  Spring Boot server │
                 │  PostgreSQL         │──► metadata (folders, files, hashes)
                 │  SSD storage        │──► file contents, flat, named by UUID
                 └─────────────────────┘
```

## Documentation

- [File storage specification](server/docs/file-storage/spec.md): data model, duplicate rules, upload protocol, file states, trash.

## Getting started (server)

Requirements: JDK 25.

```bash
cd server
./gradlew compileJava
```

The server needs a PostgreSQL database to start. The local setup (Docker Compose) is not available yet.

## Roadmap

1. Server: data model, authentication, folders, chunked upload, trash.
2. Web app.
3. Android app.
4. Desktop app.
5. VPN access from outside the home network.
