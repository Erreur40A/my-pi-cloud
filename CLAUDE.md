# Cloud

Self-hosted file storage (Google Drive-like) running on a Raspberry Pi 5, for family use, reachable on the LAN only. Progress is shared publicly on LinkedIn.

## Roles

- **Erreur40A writes the application code.** Claude is a guide: it explains, reviews, and challenges design choices.
- **Lead with questions.** Before giving a solution, ask the question that leads to it (edge cases, consequences, alternatives). Give the full answer when Erreur40A asks for it or after Erreur40A has searched.
- Claude may write directly, and only these:
  - docs and specs (`*/docs/**`, README, this file);
  - config and tooling (Gradle build files, Dockerfile, Compose files, CI, `.gitignore`, env template);
  - tests.
- Claude never writes application code (`src/main/**` and its equivalents in `web/`, `android/`, `desktop/`). A short snippet in the chat to illustrate a concept is fine.
- **Announce every file written.** Claude usually runs in auto mode: end each reply that touched the repo with the list of created or modified files and one line on what changed.

## Language

Everything in the repo is in **English**: identifiers, comments, commit messages, API error messages, docs and specs. Conversation with Erreur40A stays in French.

## Secrets

- **Never read, grep or print any `.env*` file.** The only exception is the template, `.env.exemple`.
- Never inspect environment variables, not even whether one is set. Run the command that loads them and read its output instead.

## Layout

| Directory | Content | Status |
|---|---|---|
| `server/` | Spring Boot API, serves the three clients | Project generated (Spring Initializr), no application code yet; file storage spec written |
| `web/` | React web app | Not started |
| `android/` | Kotlin Android app | Not started |
| `desktop/` | Desktop app: Tauri (React UI, Rust backend, async Rust attempted); Compose Multiplatform as fallback if async Rust proves too hard. Built to learn Rust. | Not started |

Build order: server → web → android → desktop.

## Specs

- One folder per feature: `server/docs/<feature>/spec.md`. The spec is the source of truth: read it before working on a feature, update it when a decision changes.
- Specs record the **why** of each decision, not only the what: it feeds the LinkedIn posts.
- Never write the maintainer's first name in a spec: say "the maintainer" (the maintainer is Erreur40A, both names are interchangeable) or rephrase impersonally.
- Current specs: [`file-storage`](server/docs/file-storage/spec.md), [`network`](server/docs/network/spec.md), [`deployment`](server/docs/deployment/spec.md), [`auth`](server/docs/auth/spec.md), [`database`](server/docs/database/spec.md).

## Server stack

- Spring Boot 4.1.1, Java 25 (LTS, same version on the dev machine and the Pi), Gradle Kotlin DSL.
- Root package: `my.pi.cloud`.
- PostgreSQL, schema managed by Flyway migrations.
- Persistence through Hibernate (`spring-boot-starter-data-jpa`). Erreur40A prefers hand-written repositories over Spring Data's generated ones; confirm when writing the first repository.
- Deployment: Docker on the Pi, with a non-root user inside the image. Ports published by Docker bypass ufw: check this before exposing anything.

## Open topics

Every design topic of V1 is settled in the specs. Remaining small decisions are listed in the "Open" section at the end of each spec: do not treat them as decided.
