/// Journey: the user edits an Outcome and an Action on the first launch after an
/// update, while the app is still re-projecting the store.
///
/// A launch that upgraded the domain store's schema re-projects everything merge
/// state holds (`domainStoreRebuildProvider`). Since the seeding pass, merge state
/// holds the whole local dataset on every device, so that walk covers every row
/// the user has. Every domain write goes through the store's one writer, and so
/// does the walk — if the walk keeps the writer for its whole length, each edit
/// the user makes meanwhile waits behind it: nothing is refused, nothing is
/// shown, and the screen keeps the old value until the walk is over.
///
/// So the walk has to give the writer up between small batches. This drives the
/// real start-up providers over real store files and edits through the detail
/// screen's own notifier: every edit has to be in the store while the walk is
/// still under way, the walk must not undo any of them, and they have to be there
/// after a restart.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite_async/sqlite_async.dart' show SqliteDatabase;

import 'package:jeeves/database/domain_store.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/action_draft.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/sync_stack_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/providers/user_constants.dart';
import 'package:jeeves/sync/sync_database.dart';

import '../test_helpers.dart';

/// Enough rows that the walk is many batches long, so "the edit landed while the
/// walk was still going" does not depend on timing.
const int _outcomeCount = 200;

const String _editedOutcomeId = 'outcome-7';
const String _outcomeWithEditedActionId = 'outcome-8';
const String _drifted = 'drifted from merge state';

/// One launch of the app's own start-up wiring over the files in a directory.
class _Launch {
  _Launch(Directory directory) {
    container = ProviderContainer(overrides: [
      domainStoreProvider.overrideWith((ref) async {
        final opening = await openDomainStoreIn(directory.path);
        _domainFile = opening.database;
        return opening;
      }),
      syncDatabaseProvider.overrideWith((ref) async {
        return _sync = SyncDatabase(
          NativeDatabase(File(p.join(directory.path, 'jeeves_sync.sqlite'))),
        );
      }),
    ]);
  }

  late final ProviderContainer container;
  SqliteDatabase? _domainFile;
  SyncDatabase? _sync;
  bool _closed = false;

  GtdDatabase get db => container.read(databaseProvider);

  /// Shut both stores before the next launch opens the same files.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    container.read(hostedDomainOpCaptureProvider).detach();
    await db.close();
    await _sync?.close();
    await _domainFile?.close();
    container.dispose();
  }
}

Future<void> _until(
  Future<bool> Function() condition, {
  required String what,
}) async {
  final deadline = DateTime.now().add(const Duration(minutes: 3));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting until $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// Rows of the read model the re-projection has not reached yet.
Future<int> _rowsNotYetReprojected(GtdDatabase db) async {
  final row = await db.customSelect(
    'SELECT (SELECT count(*) FROM todos WHERE notes = ?) + '
    '(SELECT count(*) FROM actions WHERE text = ?) AS remaining',
    variables: [Variable<String>(_drifted), Variable<String>(_drifted)],
  ).getSingle();
  return row.read<int>('remaining');
}

void main() {
  setUpAll(configureSqliteForTests);

  late Directory directory;
  final launches = <_Launch>[];

  _Launch launch() {
    final next = _Launch(directory);
    launches.add(next);
    return next;
  }

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    directory = Directory.systemTemp.createTempSync('jeeves_upgrade_edit_');
    addTearDown(() async {
      for (final open in launches) {
        await open.close();
      }
      launches.clear();
      try {
        directory.deleteSync(recursive: true);
      } on FileSystemException {
        // best-effort
      }
    });
  });

  /// A phone that has used Jeeves for a while: Outcomes, each with a current
  /// Action, in a store whose replay marker is already written — so a later
  /// re-projection happens because of an upgrade and for no other reason.
  Future<void> writeExistingOutcomes() async {
    final opening = await openDomainStoreIn(directory.path);
    try {
      final db = GtdDatabase(SqliteAsyncDriftConnection(opening.database));
      try {
        for (var index = 0; index < _outcomeCount; index++) {
          await db.todoDao.insertOutcome(
            id: 'outcome-$index',
            title: 'Outcome $index',
            userId: kLocalUserId,
            now: DateTime.utc(2026, 1, 1),
          );
          await db.actionDao.setCurrentAction(
            'outcome-$index',
            'Action $index',
            now: DateTime.utc(2026, 1, 1),
          );
        }
        opening.markRebuilt();
      } finally {
        await db.close();
      }
    } finally {
      await opening.database.close();
    }
  }

  /// Leave the store file one schema version behind the build about to launch,
  /// and its read model different from merge state on every row. The second is
  /// what the upgrade re-projection exists to repair, and it is what makes the
  /// walk's progress visible from outside: a row still carrying [_drifted] has
  /// not been re-projected yet.
  Future<void> leaveStoreOneVersionBehindAndDrifted() async {
    final raw = SqliteDatabase(path: p.join(directory.path, domainStoreFileName));
    await raw.initialize();
    try {
      final version =
          (await raw.get('PRAGMA user_version')).values.first! as int;
      await raw.execute('PRAGMA user_version = ${version - 1}');
      await raw.execute('UPDATE todos SET notes = ?', [_drifted]);
      await raw.execute('UPDATE actions SET text = ?', [_drifted]);
    } finally {
      await raw.close();
    }
  }

  test(
      'edits to an Outcome and an Action made while the upgrade re-projection '
      'is walking the store land before it ends, and survive a restart',
      () async {
    await writeExistingOutcomes();

    // A launch on the same schema: the sync host walks the existing rows into
    // merge state, which from then on holds the whole local dataset.
    final before = launch();
    expect(await before.container.read(domainStoreRebuildProvider.future), 0);
    final seedingHost = await before.container.read(syncHostProvider.future);
    await seedingHost.ensureMergeStateSeeded();
    await before.close();

    await leaveStoreOneVersionBehindAndDrifted();

    // The update's first launch. `main.dart` watches the host, then the rebuild.
    final upgraded = launch();
    final db = upgraded.db;
    final host = await upgraded.container.read(syncHostProvider.future);
    final reprojection =
        upgraded.container.read(domainStoreRebuildProvider.future);
    final rowsToReproject = _outcomeCount * 2;

    // The walk is under way: it has re-projected something.
    await _until(
      () async => await _rowsNotYetReprojected(db) < rowsToReproject,
      what: 'the upgrade re-projection has started',
    );

    // The user opens an Outcome and changes every field the detail screen
    // offers, then edits the current Action of another.
    final outcome = upgraded.container
        .read(taskDetailNotifierProvider(_editedOutcomeId));
    final actionOwner = upgraded.container
        .read(taskDetailNotifierProvider(_outcomeWithEditedActionId));
    final action = (await db.actionDao.getCurrentAction(
      _outcomeWithEditedActionId,
    ))!;
    final dueDate = DateTime.utc(2027, 3, 14);
    final timeContext = TimeContext.create(days: {1, 3})!;
    final edits = <Future<bool>>[
      outcome.updateTitle('Edited title'),
      outcome.updateNotes('Edited notes'),
      outcome.updateEnergyLevel('high'),
      outcome.updateTimeEstimate(45),
      outcome.updateDueDate(dueDate, clear: false),
      actionOwner.editAction(
        action.id,
        const ActionDraft(
          text: 'Edited action',
          energyLevel: 'low',
          timeEstimateMinutes: 10,
        ),
      ),
      actionOwner.setTimeContext(timeContext, actionId: action.id),
    ];

    Future<void> expectEdited(GtdDatabase store, String when) async {
      final todo = (await store.todoDao.getTodo(_editedOutcomeId))!;
      expect(todo.title, 'Edited title', reason: 'Outcome title, $when');
      expect(todo.notes, 'Edited notes', reason: 'Outcome notes, $when');
      expect(todo.energyLevel, 'high', reason: 'Outcome energy, $when');
      expect(todo.timeEstimate, 45, reason: 'Outcome estimate, $when');
      expect(todo.dueDate?.toUtc(), dueDate, reason: 'Outcome due date, $when');
      final current =
          (await store.actionDao.getCurrentAction(_outcomeWithEditedActionId))!;
      expect(current.actionText, 'Edited action', reason: 'Action text, $when');
      expect(current.energyLevel, 'low', reason: 'Action energy, $when');
      expect(current.timeEstimate, 10, reason: 'Action estimate, $when');
      expect(current.timeContext, timeContext.encode(),
          reason: 'Action time context, $when');
    }

    // Every edit is in the store...
    await _until(
      () async {
        final todo = await db.todoDao.getTodo(_editedOutcomeId);
        final current =
            await db.actionDao.getCurrentAction(_outcomeWithEditedActionId);
        return todo?.title == 'Edited title' &&
            todo?.notes == 'Edited notes' &&
            todo?.energyLevel == 'high' &&
            todo?.timeEstimate == 45 &&
            todo?.dueDate != null &&
            current?.actionText == 'Edited action' &&
            current?.timeContext == timeContext.encode();
      },
      what: 'every edit is in the store',
    );
    // ...while the walk still has rows to go.
    expect(await _rowsNotYetReprojected(db), greaterThan(0),
        reason: 'the edits must land while the re-projection is still walking '
            'the store, not after it has let go of the writer at the very end');

    expect(await Future.wait(edits), everyElement(isTrue));
    expect(await reprojection, greaterThanOrEqualTo(rowsToReproject));
    await host.drain();
    expect(await _rowsNotYetReprojected(db), 0);
    await expectEdited(db, 'once the re-projection has finished');
    await upgraded.close();

    // A restart: nothing is re-projected, and the edits are still there.
    final restarted = launch();
    expect(
        await restarted.container.read(domainStoreRebuildProvider.future), 0);
    await restarted.container.read(syncHostProvider.future);
    await expectEdited(restarted.db, 'after a restart');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
