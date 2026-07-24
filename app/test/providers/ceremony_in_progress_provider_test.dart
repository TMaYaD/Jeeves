import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/ceremony_in_progress_provider.dart';

void main() {
  group('CeremonyInProgressNotifier', () {
    late ProviderContainer container;

    setUp(() => container = ProviderContainer());
    tearDown(() => container.dispose());

    test('starts empty', () {
      expect(container.read(ceremonyInProgressProvider), isEmpty);
    });

    test('enter adds a Ritual; exit removes it', () {
      final notifier = container.read(ceremonyInProgressProvider.notifier);

      notifier.enter(RitualId.dailyPlanning);
      expect(
        container.read(ceremonyInProgressProvider),
        {RitualId.dailyPlanning},
      );

      notifier.exit(RitualId.dailyPlanning);
      expect(container.read(ceremonyInProgressProvider), isEmpty);
    });

    test('multiple Rituals coexist; re-entering an active one is idempotent', () {
      final notifier = container.read(ceremonyInProgressProvider.notifier);
      notifier.enter(RitualId.dailyPlanning);
      notifier.enter(RitualId.weeklyReview);
      notifier.enter(RitualId.weeklyReview); // duplicate enter is a no-op
      expect(
        container.read(ceremonyInProgressProvider),
        {RitualId.dailyPlanning, RitualId.weeklyReview},
      );
    });

    test('ceremonyInProgressForProvider tracks per-Ritual membership', () {
      final notifier = container.read(ceremonyInProgressProvider.notifier);

      expect(
        container.read(ceremonyInProgressForProvider(RitualId.dailyPlanning)),
        isFalse,
      );

      notifier.enter(RitualId.dailyPlanning);

      expect(
        container.read(ceremonyInProgressForProvider(RitualId.dailyPlanning)),
        isTrue,
      );
      expect(
        container.read(ceremonyInProgressForProvider(RitualId.weeklyReview)),
        isFalse,
      );
    });

    test('exit is a no-op when Ritual is not in progress', () {
      final notifier = container.read(ceremonyInProgressProvider.notifier);
      notifier.exit(RitualId.eveningShutdown);
      expect(container.read(ceremonyInProgressProvider), isEmpty);
    });
  });
}
