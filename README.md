# Jeeves

A productivity-focused todos app for mobile, web, and desktop.

## Architecture

- **Frontend:** Flutter (mobile + web + desktop)
- **Backend:** FastAPI (Python, async)
- **Sync:** PowerSync (self-hosted, Postgres-native, bidirectional)
- **Database:** PostgreSQL

## Mono-repo layout

```
jeeves/
├── app/          # Flutter app (mobile + web + desktop)
├── backend/      # FastAPI service
├── infra/        # Docker Compose, deployment configs
├── .github/
│   └── workflows/
└── README.md
```

## Getting started

See each subdirectory for setup instructions:

- [`app/README.md`](app/README.md) — Flutter app
- [`backend/README.md`](backend/README.md) — FastAPI backend
- [`infra/README.md`](infra/README.md) — Local dev infrastructure

## Testing Builds on Android

Every PR against `master` that touches `app/` automatically produces a debug APK uploaded to Firebase App Distribution. The GitHub check **PR APK Build** on the PR reflects build success or failure.

### QA tester group

The `qa` tester group currently includes:

- `apps@loonyb.in`

To add a new tester, add their email to the `qa` group in the Firebase App Distribution console.

### First-time setup

When added to the `qa` group, Firebase sends an invitation email to the tester's address. Open that email **on the Android device** and follow the link — it installs the Firebase App Tester app and accepts the invitation in one step. Do not install App Tester from the Play Store directly; the invitation link is required to associate the device with the tester account.

### Finding a build for a PR

Open the Firebase App Tester app. Each build is labeled with the PR number, title, branch, and short commit SHA. Find the entry matching the PR number you want and tap **Download**. Subsequent pushes to the same PR produce a new build that appears at the top of the list.

Re-pushes to the same PR cancel any in-progress build and produce a fresh one.

## Legacy

The `master` branch contains the legacy Pylons prototype and is archived in place.
