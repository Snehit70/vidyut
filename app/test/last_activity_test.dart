import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/activity/last_activity.dart';
import 'package:vidyut/src/activity/last_activity_repository.dart';
import 'package:vidyut/src/receive/received_text_repository.dart';

void main() {
  group('LastActivity', () {
    test('encode/decode round-trips every field', () {
      final activity = LastActivity(
        direction: ActivityDirection.received,
        summary: 'screenshot (1.2 MB)',
        counterpart: 'laptop',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1720000000000),
        outcome: ActivityOutcome.failed,
        retryable: true,
        title: 'Screenshot',
        detail: '320.1 KB  •  PNG  •  1080 × 2400',
        excerpt: 'A useful note',
        previewPath: '/tmp/preview.png',
      );

      final decoded = LastActivity.decode(activity.encode())!;

      expect(decoded.direction, ActivityDirection.received);
      expect(decoded.summary, 'screenshot (1.2 MB)');
      expect(decoded.counterpart, 'laptop');
      expect(decoded.timestamp, activity.timestamp);
      expect(decoded.outcome, ActivityOutcome.failed);
      expect(decoded.retryable, isTrue);
      expect(decoded.title, 'Screenshot');
      expect(decoded.detail, '320.1 KB  •  PNG  •  1080 × 2400');
      expect(decoded.excerpt, 'A useful note');
      expect(decoded.previewPath, '/tmp/preview.png');
    });

    test('decode returns null for empty or malformed input', () {
      expect(LastActivity.decode(null), isNull);
      expect(LastActivity.decode(''), isNull);
      expect(LastActivity.decode('not json'), isNull);
      expect(LastActivity.decode('{"direction":"sideways"}'), isNull);
    });

    test('describe reads sent/received with a relative time', () {
      final now = DateTime(2026, 7, 11, 12, 0, 0);
      final sent = LastActivity(
        direction: ActivityDirection.sent,
        summary: 'text (14 chars)',
        counterpart: 'laptop',
        timestamp: now.subtract(const Duration(minutes: 2)),
      );
      final received = LastActivity(
        direction: ActivityDirection.received,
        summary: 'text (14 chars)',
        counterpart: 'laptop',
        timestamp: now.subtract(const Duration(hours: 3)),
      );

      expect(sent.describe(now: now), 'text (14 chars) to laptop · 2m ago');
      expect(
        received.describe(now: now),
        'text (14 chars) from laptop · 3h ago',
      );
    });

    test('describe collapses very recent events to "just now"', () {
      final now = DateTime(2026, 7, 11, 12, 0, 0);
      final activity = LastActivity(
        direction: ActivityDirection.sent,
        summary: 'image',
        counterpart: 'laptop',
        timestamp: now.subtract(const Duration(seconds: 5)),
      );

      expect(activity.describe(now: now), 'image to laptop · just now');
    });
  });

  group('LastActivityRepository', () {
    test('load returns null before anything is recorded', () async {
      final repo = LastActivityRepository(MemoryLastActivityStorage());
      expect(await repo.load(), isNull);
    });

    test('record persists latest-write-wins', () async {
      final repo = LastActivityRepository(MemoryLastActivityStorage());

      await repo.record(
        LastActivity(
          direction: ActivityDirection.sent,
          summary: 'text (3 chars)',
          counterpart: 'laptop',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1),
        ),
      );
      await repo.record(
        LastActivity(
          direction: ActivityDirection.received,
          summary: 'image',
          counterpart: 'laptop',
          timestamp: DateTime.fromMillisecondsSinceEpoch(2),
        ),
      );

      final loaded = await repo.load();
      expect(loaded!.direction, ActivityDirection.received);
      expect(loaded.summary, 'image');
    });

    test('serializes concurrent history writes', () async {
      final repo = LastActivityRepository(MemoryLastActivityStorage());
      await Future.wait([
        repo.record(
          LastActivity(
            direction: ActivityDirection.sent,
            summary: 'text (1 char)',
            counterpart: 'laptop',
            timestamp: DateTime.fromMillisecondsSinceEpoch(1),
          ),
        ),
        repo.record(
          LastActivity(
            direction: ActivityDirection.sent,
            summary: 'text (2 chars)',
            counterpart: 'laptop',
            timestamp: DateTime.fromMillisecondsSinceEpoch(2),
          ),
        ),
      ]);

      expect((await repo.loadAll()).length, 2);
    });

    test('prunes persisted event keys to the retained timeline', () async {
      final storage = MemoryLastActivityStorage();
      final repo = LastActivityRepository(storage);

      for (var index = 0; index < 35; index++) {
        await repo.record(
          LastActivity(
            direction: ActivityDirection.sent,
            summary: 'text ($index chars)',
            counterpart: 'laptop',
            timestamp: DateTime(2026, 1, 1).add(Duration(seconds: index)),
            payloadId: 'payload-$index',
          ),
        );
      }

      final eventKeys = (await storage.readAll()).keys.where(
        (key) => key.startsWith('vidyut.activity.event.'),
      );
      expect(eventKeys, hasLength(30));
      expect(await repo.loadAll(), hasLength(30));
    });

    test('emits the updated timeline after a record', () async {
      final repo = LastActivityRepository(MemoryLastActivityStorage());
      final changes = expectLater(
        repo.changes,
        emits(
          predicate<List<LastActivity>>(
            (items) => items.length == 1 && items.single.summary == 'image',
          ),
        ),
      );

      await repo.record(
        LastActivity(
          direction: ActivityDirection.received,
          summary: 'image',
          counterpart: 'laptop',
          timestamp: DateTime.fromMillisecondsSinceEpoch(3),
        ),
      );
      await changes;
    });
  });

  test('keeps concurrent repository-isolate writes in the timeline', () async {
    final storage = MemoryLastActivityStorage();
    final first = LastActivityRepository(storage);
    final second = LastActivityRepository(storage);

    await Future.wait([
      first.record(
        LastActivity(
          direction: ActivityDirection.sent,
          summary: 'text (1 chars)',
          counterpart: 'laptop',
          timestamp: DateTime(2026, 1, 1, 0, 0, 1),
        ),
      ),
      second.record(
        LastActivity(
          direction: ActivityDirection.received,
          summary: 'text (2 chars)',
          counterpart: 'laptop',
          timestamp: DateTime(2026, 1, 1, 0, 0, 2),
        ),
      ),
    ]);

    expect(await first.loadAll(), hasLength(2));
  });

  test('serializes concurrent received text history writes', () async {
    final repo = ReceivedTextRepository(MemoryReceivedPayloadStorage());
    await Future.wait([
      repo.saveLatest('one', id: 'id-one'),
      repo.saveLatest('two', id: 'id-two'),
    ]);

    expect(await repo.loadById('id-one'), 'one');
    expect(await repo.loadById('id-two'), 'two');
  });

  test('bounds received text history by total payload bytes', () async {
    final repo = ReceivedTextRepository(MemoryReceivedPayloadStorage());
    final largeText = 'x' * (16 * 1024 * 1024);

    await repo.saveLatest(largeText, id: 'old');
    await repo.saveLatest(largeText, id: 'new');

    expect(await repo.loadById('new'), largeText);
    expect(await repo.loadById('old'), isNull);
  });

  test('does not retain one text payload larger than the byte limit', () async {
    final repo = ReceivedTextRepository(MemoryReceivedPayloadStorage());
    final oversizedText = 'x' * (32 * 1024 * 1024);

    await repo.saveLatest(oversizedText, id: 'oversized');

    expect(await repo.loadById('oversized'), isNull);
  });
}
