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
fvm flutter pub run build_runner build --delete-conflicting-outputs
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
├── services/
│   ├── sync_service.dart        # PowerSync offline-first sync
│   ├── api_service.dart         # FastAPI REST client (Dio)
│   ├── notification_service.dart
│   ├── location_service.dart
│   └── ai_service.dart          # NL parse / suggestions (proxied through backend)
└── screens/          # UI screens (TBD)
```

**State management:** Riverpod  
**Local storage:** Drift (SQLite, offline-first)  
**Sync:** PowerSync (`powersync` Dart package, self-hosted service)

## Platform channels

- `ios/Runner/` — Siri Shortcuts, CoreLocation background, WidgetKit
- `android/app/` — Google Assistant App Actions, WorkManager
