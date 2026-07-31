/// An offline relaunch must not cost an enrolled device its enrolment (#606).
///
/// The whole journey, through the production providers: session restore →
/// `currentUserIdProvider` → `syncStackProvider` → `syncLifecycleProvider` → the
/// capture seam → the outbox → the log. That chain is the reason #606 was
/// data loss rather than a spurious sign-out prompt: clearing credentials resets
/// the user to `'local'`, which refuses the stack, settles the seam **silent**,
/// and — with the initial-upload marker already set from an earlier online run —
/// leaves no path that would ever re-carry the session's writes.
///
/// Three launches, one per side of the decision, all with the *same* stored
/// credentials and the *same* expired access token. Only the answer from
/// `POST /session/refresh` differs:
///
/// 1. **The socket is dead** (`connectionError`) — inconclusive. Credentials
///    retained, the account adopted, the seam bound, the write queued, and once
///    the network returns a second device converges to it.
/// 2. **A corroborated 401** — authoritative. Credentials cleared, the seam
///    silent, and a write authors nothing. The over-correction guard: a genuinely
///    revoked device must still sign out.
/// 3. **A bare 401 from a captive portal** — inconclusive again, and this is the
///    case an implementer keying on `statusCode` alone gets wrong. A hotel gateway
///    answering 401 must not be able to destroy an enrolment.
///
/// **What is the harness's, and what is not.** The Dio side is a scripted
/// [HttpClientAdapter] at Dio's own boundary, so the real `ApiService`
/// interceptor chain runs (precedent: `http_sync_transport_test.dart`). The sync
/// side is the harness's `FakeSyncServer`/`DeviceLink`. `syncStackProvider` is
/// overridden — but with the production body, guard included — because the
/// epoch-key store and the Argon2id floor it assembles with are the platform
/// keychain and a deliberate second of CPU; `sync_signup_flow_test.dart` covers
/// that assembly over the same `SyncStack.assemble`. Everything the session
/// decision touches — `authTokenProvider`, `currentUserIdProvider`,
/// `domainOpCaptureProvider`, `databaseProvider`, `syncLifecycleProvider`,
/// `PasswordAuthProvider`, `AuthService` — is production.
@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/auth/auth_mode.dart';
import 'package:jeeves/auth/password/password_auth_provider.dart';
import 'package:jeeves/auth/session_gate.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/sync_lifecycle_provider.dart';
import 'package:jeeves/providers/sync_stack_provider.dart';
import 'package:jeeves/providers/user_constants.dart';
import 'package:jeeves/services/api_service.dart';
import 'package:jeeves/services/auth_service.dart';
import 'package:jeeves/sync/device_key_store.dart';
import 'package:jeeves/sync/domain_op_capture.dart';
import 'package:jeeves/sync/pending_rotation_store.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_lifecycle.dart';
import 'package:jeeves/sync/sync_stack.dart';
import 'package:jeeves/sync/workspace_key_store.dart';

import '../test_helpers.dart';
import 'harness/fake_sync_server.dart';
import 'harness/reduced_state.dart';
import 'harness/sim_device.dart' show DeviceLink, FakeClock, harnessKdfParameters;
import 'harness/sim_workspace.dart' show simulationStartWallMs;
import 'harness/stack_phone.dart';

const String _userId = 'relaunch-user';
const String _onlineOutcomeId = '11111111-1111-4111-8111-111111111111';
const String _offlineOutcomeId = '22222222-2222-4222-8222-222222222222';

// ---------------------------------------------------------------------------
// Secure storage — the platform keychain, which survives a process death
// ---------------------------------------------------------------------------

class _FakeSecureStorage implements SecureStorage {
  final Map<String, String> entries = {};

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String value) async => entries[key] = value;

  @override
  Future<void> delete(String key) async => entries.remove(key);
}

// ---------------------------------------------------------------------------
// The Dio side: one scripted answer for /session/refresh, nothing else allowed
// ---------------------------------------------------------------------------

/// Answers `POST /session/refresh` with whatever the launch scripted, and refuses
/// every other path — nothing in this test may reach a real socket.
class _RefreshAdapter implements HttpClientAdapter {
  _RefreshAdapter(this._answer);

  /// Null means "the socket is dead", which is what an offline relaunch is.
  final ResponseBody? Function() _answer;

  int refreshRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!options.path.endsWith('/session/refresh')) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'unexpected request to ${options.path}',
      );
    }
    refreshRequestCount++;
    final answer = _answer();
    if (answer == null) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'network is unreachable',
      );
    }
    return answer;
  }

  @override
  void close({bool force = false}) {}
}

/// The socket is down: no bytes either way. What an offline relaunch sees.
ResponseBody? _unreachable() => null;

/// The Jeeves backend rejecting the refresh token, both corroborators present —
/// `backend/app/auth/routes.py`, pinned by `backend/tests/test_sessions.py`.
ResponseBody? _corroboratedRejection() => ResponseBody.fromString(
      '{"detail": "Invalid or expired refresh token"}',
      401,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        'www-authenticate': ['Bearer'],
      },
    );

/// A captive portal: a bare 401 with a login page, no `detail`, no challenge
/// header. Not the Jeeves backend, and it must not be believed.
ResponseBody? _captivePortal() => ResponseBody.fromString(
      '<html><body>Sign in to HotelWiFi to continue</body></html>',
      401,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );

// ---------------------------------------------------------------------------
// JWTs
// ---------------------------------------------------------------------------

String _jwt(String sub, {required int secondsFromNow}) {
  final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
  final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + secondsFromNow;
  final payload = base64Url
      .encode(utf8.encode('{"sub":"$sub","exp":$exp}'))
      .replaceAll('=', '');
  return '$header.$payload.sig';
}

// ---------------------------------------------------------------------------
// One device, across process deaths
// ---------------------------------------------------------------------------

/// What the platform keeps across a relaunch, and what a launch rebuilds.
///
/// Kept: both SQLite files, the keychain-tier stores (device keys, epoch keys,
/// pending rotations, secure storage) and the link to the server. Rebuilt: the
/// sync store handle, the domain store handle, the **capture seam**, the stack
/// and the whole `ProviderContainer`. The fresh seam is the point — it starts
/// undecided, exactly as a real process does, and who settles it is what #606
/// turned on.
class _Device {
  _Device._(this.files, this.link, this.clock);

  static _Device create(FakeSyncServer server, FakeClock clock) {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    return _Device._(
      Directory.systemTemp.createTempSync('jeeves-offline-relaunch-'),
      DeviceLink(server.connectAsUser(_userId)),
      clock,
    );
  }

  final Directory files;
  final DeviceLink link;
  final FakeClock clock;

  final keyStore = InMemoryDeviceKeyStore();
  final workspaceKeys = InMemoryWorkspaceKeyStore();
  final pendingRotations = InMemoryPendingRotationStore();
  final secureStorage = _FakeSecureStorage();

  /// Both tokens in the keychain: an enrolled, signed-in device at rest.
  void storeCredentials({required int accessTokenValidForSeconds}) {
    secureStorage.entries['jwt_token'] =
        _jwt(_userId, secondsFromNow: accessTokenValidForSeconds);
    secureStorage.entries['refresh_token'] = 'stored-refresh-token';
  }

  bool get hasAccessToken => secureStorage.entries.containsKey('jwt_token');
  bool get hasRefreshToken => secureStorage.entries.containsKey('refresh_token');

  Future<_Launch> launch({ResponseBody? Function() refreshAnswer = _unreachable}) async {
    // A cold start has not answered yet; the global notifier is the router's, so
    // each launch starts it where a real process does.
    sessionGateNotifier.value = SessionGate.checking;

    final syncStore = SyncDatabase(NativeDatabase(File('${files.path}/sync.sqlite')));
    final adapter = _RefreshAdapter(refreshAnswer);
    final api = ApiService(baseUrl: 'http://jeeves.invalid', adapter: adapter);
    final authService = AuthService(apiService: api, storage: secureStorage);

    late final ProviderContainer container;
    container = ProviderContainer(overrides: [
      apiServiceProvider.overrideWithValue(api),
      authServiceProvider.overrideWithValue(authService),
      authImplProvider.overrideWith(PasswordAuthProvider.new),
      // The domain read model over a real file, built through the production
      // provider's own body so it takes the seam from `domainOpCaptureProvider`.
      // Closed by [_Launch.end] rather than `onDispose`, so the file is released
      // before the next launch reopens it.
      databaseProvider.overrideWith(
        (ref) => GtdDatabase(
          NativeDatabase(File('${files.path}/domain.sqlite')),
          opCapture: ref.read(domainOpCaptureProvider),
        ),
      ),
      syncDatabaseProvider.overrideWith((ref) async => syncStore),
      deviceKeyStoreProvider.overrideWithValue(keyStore),
      userTransportProvider.overrideWithValue(link),
      // The production body verbatim — guard included, because refusing
      // `'local'` is a load-bearing hop in the chain under test — with the three
      // keychain-tier stores and the KDF cost swapped for the harness's.
      syncStackProvider.overrideWith((ref) async {
        ref.keepAlive();
        final userId = ref.watch(currentUserIdProvider);
        if (userId == kLocalUserId) {
          throw StateError('sign in before enrolling this device');
        }
        return SyncStack.assemble(
          userId: userId,
          database: await ref.watch(syncDatabaseProvider.future),
          keyStore: ref.watch(deviceKeyStoreProvider),
          userTransport: ref.watch(userTransportProvider),
          domain: ref.watch(databaseProvider),
          nowMs: () => clock.nowMs,
          workspaceKeys: workspaceKeys,
          pendingRotations: pendingRotations,
          kdfParameters: harnessKdfParameters,
          kdfFloor: harnessKdfParameters,
        );
      }),
    ]);

    // Registered before the restore is awaited, not after the test's assertions
    // pass: the first failing `expect` — the situation these regression tests
    // exist to produce — would otherwise leave the container and both native
    // database files open while [close] deletes the directory under them.
    // [_Launch.end] is idempotent, so the explicit call in the test body and this
    // one are safe in either order.
    final launch = _Launch(
      container: container,
      syncStore: syncStore,
      adapter: adapter,
    );
    addTearDown(launch.end);

    // Eager materialisation, exactly as `main.dart` does it: the restore is what
    // everything downstream waits on.
    launch.accessToken = await container.read(authTokenProvider.future);
    return launch;
  }

  void close() => files.deleteSync(recursive: true);
}

class _Launch {
  _Launch({
    required this.container,
    required this.syncStore,
    required this.adapter,
  });

  final ProviderContainer container;
  final SyncDatabase syncStore;
  final _RefreshAdapter adapter;

  /// What `authTokenProvider` resolved to — non-null whenever the device stayed
  /// signed in, including on the retained-but-unverified path.
  ///
  /// Assigned once by [_Device.launch] after teardown is registered, so a restore
  /// that throws still releases the container and both database files.
  late final String? accessToken;

  bool _ended = false;

  String get userId => container.read(currentUserIdProvider);
  SessionGate get gate => sessionGateNotifier.value;
  WorkspaceRoutingOpCapture get capture => container.read(domainOpCaptureProvider);
  GtdDatabase get domain => container.read(databaseProvider);

  Future<SyncStack> get stack => container.read(syncStackProvider.future);

  /// The lifecycle the provider built, with its un-awaited first activation
  /// joined — `activate()` is single-flight, so this waits on the one already
  /// running rather than starting a second.
  Future<SyncLifecycle?> settledLifecycle() async {
    final lifecycle = await container.read(syncLifecycleProvider.future);
    if (lifecycle != null) await lifecycle.activate();
    return lifecycle;
  }

  /// Every op this device has ever authored. Acknowledged rows are kept, so this
  /// only ever grows — which is what makes it the right measure of "did that
  /// write author anything".
  Future<int> authoredOpCount() async =>
      (await syncStore.select(syncStore.outbox).get()).length;

  /// Authored but not yet acknowledged: the durable queue an offline write lands
  /// in, and what a flush drains.
  Future<int> unsentOpCount() async => (await (syncStore.select(syncStore.outbox)
            ..where((row) => row.sentAt.isNull()))
          .get())
      .length;

  Future<InitialUploadStateRow?> marker() =>
      InitialUploadMarkerStore(syncStore).read(_userId);

  /// Process death: dispose the container (which deactivates the lifecycle) and
  /// release both files before the next launch reopens them.
  ///
  /// Idempotent, so the test body may end a launch explicitly before relaunching
  /// while the registered teardown still guarantees release on a failed assertion.
  Future<void> end() async {
    if (_ended) return;
    _ended = true;
    final domainStore = domain;
    final lifecycle = await container.read(syncLifecycleProvider.future);
    await lifecycle?.deactivate();
    container.dispose();
    await domainStore.close();
    await syncStore.close();
  }
}

/// One outcome through the real DAO — a domain write, exactly as a screen makes
/// one.
Future<void> _writeOutcome(GtdDatabase domain, String id, String title,
        FakeClock clock) =>
    domain.todoDao
        .insertOutcome(id: id, title: title, userId: _userId, now: clock.asDateTime);

void main() {
  setUpAll(configureSqliteForTests);

  late FakeSyncServer server;
  late FakeClock clock;
  late _Device device;

  setUp(() {
    server = FakeSyncServer();
    clock = FakeClock(simulationStartWallMs);
    device = _Device.create(server, clock);
    addTearDown(device.close);
    addTearDown(() => sessionGateNotifier.value = SessionGate.checking);
  });

  /// The precondition that makes #606 permanent rather than cosmetic: one online
  /// launch that enrols, uploads, and **sets the initial-upload marker** — after
  /// which no marker-gated walk will ever re-carry a dropped write again.
  ///
  /// Returns the recovery passphrase, so a second device can converge later.
  Future<String> runOnlineLaunch() async {
    device.storeCredentials(accessTokenValidForSeconds: 3600);
    final launch = await device.launch();

    // Signed in, on a token that is still good.
    expect(launch.userId, _userId);
    expect(launch.accessToken, isNotNull);

    final passphrase = (await (await launch.stack).enrolment.enrolFirstDevice())
        .passphrase;
    expect(await launch.settledLifecycle(), isNotNull);
    expect(launch.capture.isBound, isTrue);
    expect(await launch.marker(), isNotNull,
        reason: 'the marker is the precondition for permanence');

    clock.advance(1000);
    await _writeOutcome(launch.domain, _onlineOutcomeId, 'Agreed online', clock);
    await (await launch.settledLifecycle())!.flushOutboxNow();
    expect(server.storedOps, isNotEmpty);
    expect(await launch.unsentOpCount(), 0,
        reason: 'the online launch left the queue drained');

    await launch.end();
    return passphrase;
  }

  test('an offline relaunch keeps the enrolment, queues the write, and converges '
      'once the network returns', () async {
    final passphrase = await runOnlineLaunch();

    // --- the relaunch: expired access token, dead socket ---------------------
    device.storeCredentials(accessTokenValidForSeconds: -1);
    device.link.online = false;
    final relaunch = await device.launch(refreshAnswer: _unreachable);

    // The refresh was attempted and told us nothing.
    expect(relaunch.adapter.refreshRequestCount, 1);

    // AC-1, four assertions. This is the whole issue.
    expect(device.hasAccessToken, isTrue, reason: 'the access token was destroyed');
    expect(device.hasRefreshToken, isTrue,
        reason: 'the refresh token was destroyed — the enrolment is gone');
    expect(relaunch.userId, _userId,
        reason: 'reset to the local placeholder; the sync spine hangs off this');
    expect(relaunch.accessToken, isNotNull,
        reason: 'the provider must match the Authorization header already set');

    final lifecycle = await relaunch.settledLifecycle();
    expect(lifecycle, isNotNull, reason: 'no lifecycle was built for the account');
    expect(relaunch.gate, SessionGate.ready);
    expect(relaunch.capture.isBound, isTrue,
        reason: 'the seam was settled silent — every write this session is lost');

    // A write while offline: authored into the durable outbox, and the marker
    // untouched, so nothing here depends on a walk that will never run again.
    final markerBefore = await relaunch.marker();
    clock.advance(1000);
    await _writeOutcome(relaunch.domain, _offlineOutcomeId, 'Agreed offline', clock);
    expect(await relaunch.unsentOpCount(), greaterThan(0),
        reason: 'the offline write authored nothing');
    expect((await relaunch.marker())!.completedAtUtcMs,
        markerBefore!.completedAtUtcMs);

    // --- the network comes back ---------------------------------------------
    device.link.online = true;
    expect(await lifecycle!.activate(), SyncActivation.active);
    await lifecycle.flushOutboxNow();
    expect(await relaunch.unsentOpCount(), 0, reason: 'the queue did not drain');

    // --- and a second device converges to the offline write ------------------
    final b = await StackPhone.create(
      label: 'B', userId: _userId, server: server, clock: clock);
    addTearDown(b.close);
    await b.enrolWithPassphrase(passphrase);
    expect(await b.activate(), SyncActivation.active);

    expect(
      (await domainRows(b.domain, 'todos')).map((row) => row['id']),
      containsAll(<String>[_onlineOutcomeId, _offlineOutcomeId]),
      reason: 'the offline session never reached the log',
    );

    await relaunch.end();
  });

  test('a corroborated 401 still signs the device out, and its writes author '
      'nothing', () async {
    await runOnlineLaunch();

    device.storeCredentials(accessTokenValidForSeconds: -1);
    final relaunch = await device.launch(refreshAnswer: _corroboratedRejection);

    // AC-2: the server said no, with proof it was the server.
    expect(relaunch.adapter.refreshRequestCount, 1);
    expect(device.hasAccessToken, isFalse);
    expect(device.hasRefreshToken, isFalse);
    expect(relaunch.userId, kLocalUserId);
    expect(relaunch.accessToken, isNull);
    expect(relaunch.gate, SessionGate.signedOut);

    // No lifecycle, and the seam settled silent rather than left buffering.
    expect(await relaunch.settledLifecycle(), isNull);
    expect(relaunch.capture.isBound, isFalse);

    // The sharp end: silent is not undecided. A write now authors nothing at all,
    // and a later bind has nothing to drain. Measured as a delta, because the
    // online launch's own acknowledged ops are kept in the same table.
    final authoredBefore = await relaunch.authoredOpCount();
    clock.advance(1000);
    await _writeOutcome(relaunch.domain, _offlineOutcomeId, 'Written signed out', clock);
    expect(await relaunch.authoredOpCount(), authoredBefore,
        reason: 'a signed-out device authored an op');

    await relaunch.end();
  });

  test('a captive portal answering a bare 401 does not destroy the enrolment',
      () async {
    await runOnlineLaunch();

    device.storeCredentials(accessTokenValidForSeconds: -1);
    device.link.online = false;
    final relaunch = await device.launch(refreshAnswer: _captivePortal);

    // A 401 arrived, and it is not the Jeeves backend's: no JSON `detail`, no
    // `WWW-Authenticate`. Inconclusive, so the AC-1 outcome, not the AC-2 one.
    expect(relaunch.adapter.refreshRequestCount, 1);
    expect(device.hasAccessToken, isTrue);
    expect(device.hasRefreshToken, isTrue);
    expect(relaunch.userId, _userId);
    expect(relaunch.gate, SessionGate.ready);

    expect(await relaunch.settledLifecycle(), isNotNull);
    expect(relaunch.capture.isBound, isTrue);

    clock.advance(1000);
    await _writeOutcome(relaunch.domain, _offlineOutcomeId, 'Agreed behind a portal', clock);
    expect(await relaunch.unsentOpCount(), greaterThan(0),
        reason: 'a captive portal cost the user their session');

    await relaunch.end();
  });
}
