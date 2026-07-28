/// The signal protocol as the client sees it: two frame kinds and a deadline.
///
/// The wire contract is `backend/app/sync/routes.py`'s `signal_socket`: a poke
/// is a zero-length text frame meaning "run a sync from your cursor now", a
/// keepalive is the fixed literal [keepaliveFrame], and nothing else is ever
/// sent. Both live here rather than in each transport so the real socket and
/// the harness's in-process one are held to one implementation of the rule.
library;

import 'dart:async';

import 'sync_transport.dart';

/// The one non-empty frame the server ever sends. Matched as a literal: any
/// other non-empty frame is a protocol violation, not an unknown extension.
///
/// Application-level rather than a WebSocket protocol PING because protocol
/// pings are unobservable from a browser client — `IOWebSocketChannel` exposes
/// `pingInterval`, the web adapter has no equivalent, and the client needs to
/// see liveness on every platform.
const String keepaliveFrame = 'ping';

/// Server-side keepalive cadence (`Settings.signal_keepalive_interval_seconds`).
/// Mirrored here because the client's idle deadline is defined in terms of it.
const Duration signalKeepaliveInterval = Duration(seconds: 25);

/// Three missed keepalives. A half-open socket never errors on its own, so
/// without this deadline the reconnect ladder would have no way to fire and the
/// device would sit silently disconnected until the next manual sync.
const Duration signalIdleDeadline = Duration(seconds: 75);

/// Close codes the server refuses a socket with. The client's reconnect ladder
/// branches on these exact numbers, so they are protocol, not policy.
const int signalCloseProtocolError = 4400;
const int signalCloseUnauthenticated = 4401;
const int signalCloseForbidden = 4403;

/// The WebSocket application close-code range (RFC 6455 §7.4.2).
const int _applicationCloseCodeFloor = 4000;
const int _applicationCloseCodeCeiling = 4999;

/// Schedules the idle deadline. Injected so the harness can drive it off a
/// manually advanced clock rather than waiting out 75 real seconds.
typedef SignalTimerFactory = Timer Function(Duration duration, void Function() callback);

/// One open signal socket, from the transport that opened it.
class SignalSocket {
  SignalSocket({
    required this.frames,
    required this.close,
    this.closeCode,
  });

  /// Raw inbound frames. Typed loosely because a real socket can deliver bytes
  /// where text was promised, and that is a protocol violation to be caught,
  /// not a type error to be crashed on.
  final Stream<Object?> frames;

  /// Releases the socket. Called exactly once, on every exit path.
  final Future<void> Function() close;

  /// The close code once [frames] is done, when the underlying socket exposes
  /// one — how a refusal (4401/4403) reaches the caller, since a server that
  /// closes cleanly produces a done, not an error.
  final int? Function()? closeCode;
}

/// The poke stream [SyncTransport.newSeqSignals] promises, over a raw socket.
///
/// One socket per *call*, not per listen. The returned stream is
/// single-subscription and cold: [open] runs when it is first listened to, with
/// a freshly read token, and cancelling closes the socket. Once cancelled the
/// stream is spent — re-listening does not reopen anything. Reconnecting means
/// calling [SyncTransport.newSeqSignals] again for a new stream and a new
/// socket, which is what `SignalListener._subscribe` does on every reconnect.
///
/// Keepalives are consumed here — they reset the idle deadline and are never
/// forwarded — so a listener downstream sees pokes and nothing else. Every
/// failure mode arrives as a stream error: a refusal carries the server's close
/// code, and a lost, silent or misbehaving socket carries
/// [SyncTransportException.unreachable] or the protocol-violation code.
Stream<void> decodeSignalFrames(
  Future<SignalSocket> Function() open, {
  Duration idleDeadline = signalIdleDeadline,
  SignalTimerFactory timerFactory = Timer.new,
}) {
  final controller = StreamController<void>();
  SignalSocket? socket;
  StreamSubscription<Object?>? frames;
  Timer? deadline;
  var released = false;

  Future<void> release() async {
    if (released) return;
    released = true;
    deadline?.cancel();
    deadline = null;
    await frames?.cancel();
    frames = null;
    await socket?.close();
    socket = null;
  }

  void fail(Object error) {
    if (controller.isClosed) return;
    controller.addError(error);
    release().whenComplete(controller.close);
  }

  void armDeadline() {
    deadline?.cancel();
    deadline = timerFactory(
      idleDeadline,
      () => fail(
        const SyncTransportException.unreachable(
          'no poke or keepalive within the signal idle deadline',
        ),
      ),
    );
  }

  void onFrame(Object? frame) {
    // Any inbound frame proves the socket is alive, keepalive or not.
    armDeadline();
    if (frame == '') {
      controller.add(null);
      return;
    }
    if (frame == keepaliveFrame) return;
    fail(
      SyncTransportException(
        signalCloseProtocolError,
        'the signal socket sent a frame that is neither a poke nor a '
        'keepalive: ${frame is String ? frame : frame.runtimeType}',
      ),
    );
  }

  void onDone() {
    final code = socket?.closeCode?.call();
    fail(
      code != null && code >= _applicationCloseCodeFloor && code <= _applicationCloseCodeCeiling
          ? SyncTransportException(code, 'the signal socket was closed with $code')
          : const SyncTransportException.unreachable('the signal socket closed'),
    );
  }

  controller.onListen = () {
    armDeadline();
    open().then(
      (opened) {
        if (released) {
          unawaited(opened.close());
          return;
        }
        socket = opened;
        frames = opened.frames.listen(
          onFrame,
          onError: fail,
          onDone: onDone,
          cancelOnError: false,
        );
      },
      onError: fail,
    );
  };
  controller.onCancel = release;
  return controller.stream;
}
