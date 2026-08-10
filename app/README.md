# Jeeves — Flutter App

Cross-platform frontend for mobile (iOS + Android), web, and desktop.

## Prerequisites

The Flutter SDK version is pinned in [`.fvmrc`](./.fvmrc) — check that file
for the exact version. CI enforces the pin and fails any PR where
`flutter pub get` mutates `pubspec.lock`, typically a sign that someone
resolved against a different SDK (the Dart toolchain vendors `meta`,
`analyzer`, `dart_style`, etc., so SDK skew silently rewrites those entries).

**Recommended: FVM.** Manages the pinned SDK per-project without touching
your system Flutter:

```bash
brew tap leoafarias/fvm && brew install fvm   # one-time
cd app && fvm install && fvm use              # reads .fvmrc, downloads + symlinks into app/.fvm/
```

Then run Flutter via `fvm flutter …`, or point your IDE at
`app/.fvm/flutter_sdk` (VS Code: "Dart: Flutter Sdk Path" setting; Android
Studio: Languages & Frameworks → Flutter → Flutter SDK path).

**Without FVM:** install the Flutter version listed in `.fvmrc` system-wide.
CI will reject PRs built against a different version.

## Setup

```bash
fvm flutter pub get   # or: flutter pub get
fvm flutter pub run build_runner build
```

## Run

```bash
# Mobile (device/emulator connected)
flutter run

# Web
flutter run -d chrome

# macOS
flutter run -d macos
```

## Architecture

```
lib/
├── main.dart
├── models/           # Freezed data models (Todo, List, Reminder, Location, RecurrenceRule)
├── database/         # Drift schema + DAOs, and the domain store'''s open path
├── sync/             # the op-log spine: capture seam, client, reducer, projector
├── providers/        # Riverpod providers
├── services/
│   ├── api_service.dart         # FastAPI REST client (Dio)
│   ├── notification_service.dart
│   └── location_service.dart
└── screens/          # UI screens
```

**State management:** Riverpod  
**Local storage:** Drift over two SQLite files — `jeeves_domain.sqlite` (the domain read model) and `jeeves_sync.sqlite` (the op log)  
**Sync:** the op log, activated at enrolment (docs/SYNC.md, ADR-0026, ADR-0034)

## Platform channels

- `ios/Runner/` — Siri Shortcuts, CoreLocation background, WidgetKit
- `android/app/` — Google Assistant App Actions, WorkManager
