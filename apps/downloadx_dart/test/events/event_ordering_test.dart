import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

import '../helpers/harness.dart';
import '../helpers/mock_io.dart';

const _url = 'https://h/file.bin';

void main() {
  group('download event ordering', () {
    test(
        'downloading precedes progress; completed event follows completed state',
        () async {
      final h = await Harness.create();
      h.io.fetcher
          .route(_url, MockRoute(body: deterministicBytes(500), etag: 'E1'));
      final dl = await h.manager.addUrl(_url);

      final order = <String>[];
      dl.emitter.on((e) {
        if (e is StateChangeEvent) {
          order.add('state:${e.current.name}');
        } else if (e is ProgressEvent) {
          order.add('progress');
        } else if (e is CompletedEvent) {
          order.add('completed');
        }
      });

      await dl.start();

      final firstDownloading = order.indexOf('state:downloading');
      final firstProgress = order.indexOf('progress');
      final completedState = order.lastIndexOf('state:completed');
      final completedEvent = order.indexOf('completed');

      expect(firstDownloading, greaterThanOrEqualTo(0));
      expect(firstProgress, greaterThan(firstDownloading));
      expect(completedState, greaterThanOrEqualTo(0));
      // The terminal CompletedEvent is emitted after the state flips to completed.
      expect(completedEvent, greaterThan(completedState));
    });

    test('chunk lifecycle goes through downloading then completed', () async {
      final h = await Harness.create();
      h.io.fetcher
          .route(_url, MockRoute(body: deterministicBytes(400), etag: 'E1'));
      final dl = await h.manager.addUrl(_url);

      final statuses = <ChunkStatus>[];
      dl.emitter.onType<ChunkLifecycleEvent>((e) => statuses.add(e.status));

      await dl.start();

      expect(statuses, contains(ChunkStatus.downloading));
      expect(statuses, contains(ChunkStatus.completed));
    });
  });

  group('payload contracts', () {
    test('progress percent stays within [0,100]; completed totalBytes matches',
        () async {
      final body = deterministicBytes(777);
      final h = await Harness.create();
      h.io.fetcher.route(_url, MockRoute(body: body, etag: 'E1'));
      final dl = await h.manager.addUrl(_url);

      final percents = <double>[];
      CompletedEvent? completed;
      dl.emitter.onType<ProgressEvent>((e) {
        if (e.percent != null) percents.add(e.percent!);
      });
      dl.emitter.onType<CompletedEvent>((e) => completed = e);

      await dl.start();

      for (final p in percents) {
        expect(p, inInclusiveRange(0, 100));
      }
      expect(completed, isNotNull);
      expect(completed!.totalBytes, 777);
      expect(completed!.filename, 'file.bin');
    });

    test('chunk progress never reports more downloaded than its length',
        () async {
      final h = await Harness.create(targetChunkCount: 4, minChunkSize: 64);
      h.io.fetcher.route(
          _url,
          MockRoute(
              body: deterministicBytes(1000), etag: 'E1', streamChunkSize: 16));
      final dl = await h.manager.addUrl(_url);

      var violated = false;
      dl.emitter.onType<ChunkProgressEvent>((e) {
        if (e.downloadedBytes > e.length) violated = true;
      });

      await dl.start();
      expect(violated, isFalse);
    });
  });
}
