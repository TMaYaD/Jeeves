/// The calendar adapter's entry point: `*_stub` / `*_io` / `*_web` behind a
/// conditional export (docs/ARCHITECTURE.md § Extension seams).
library;

export 'calendar_types.dart';
export 'calendar_source_stub.dart'
    if (dart.library.io) 'calendar_source_io.dart'
    if (dart.library.js_interop) 'calendar_source_web.dart';
