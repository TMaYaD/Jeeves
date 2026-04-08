# Jeeves — Flutter App

Cross-platform frontend for mobile (iOS + Android), web, and desktop.

## Prerequisites

- Flutter SDK ≥ 3.22
- Dart SDK ≥ 3.0

## Setup

```bash
flutter pub get
flutter pub run build_runner build --delete-conflicting-outputs
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
│   ├── sync_service.dart        # Electric SQL offline-first sync
│   ├── api_service.dart         # FastAPI REST client (Dio)
│   ├── notification_service.dart
│   ├── location_service.dart
│   └── ai_service.dart          # NL parse / suggestions (proxied through backend)
└── screens/          # UI screens (TBD)
```

**State management:** Riverpod  
**Local storage:** Drift (SQLite, offline-first)  
**Sync:** Electric SQL client (wired in once Flutter package is published)

## Platform channels

- `ios/Runner/` — Siri Shortcuts, CoreLocation background, WidgetKit
- `android/app/` — Google Assistant App Actions, WorkManager
