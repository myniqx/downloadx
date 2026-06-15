import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

void main() {
  group('EventEmitter', () {
    test('dispatches to all listeners synchronously in order', () {
      final emitter = EventEmitter();
      final seen = <String>[];
      emitter.on((e) => seen.add('a'));
      emitter.on((e) => seen.add('b'));
      emitter.emit(StateChangeEvent('d',
          previous: DownloadState.idle, current: DownloadState.downloading));
      expect(seen, ['a', 'b']);
    });

    test('onType filters by subtype', () {
      final emitter = EventEmitter();
      var progress = 0;
      var state = 0;
      emitter.onType<ProgressEvent>((_) => progress += 1);
      emitter.onType<StateChangeEvent>((_) => state += 1);
      emitter.emit(ProgressEvent('d',
          totalBytes: 100,
          downloadedBytes: 50,
          totalSpeed: 0,
          activeChunks: 1,
          percent: 50,
          etaMs: null));
      emitter.emit(StateChangeEvent('d',
          previous: DownloadState.idle, current: DownloadState.completed));
      expect(progress, 1);
      expect(state, 1);
    });

    test('disposer removes listener', () {
      final emitter = EventEmitter();
      var count = 0;
      final dispose = emitter.on((_) => count += 1);
      emitter.emit(StateChangeEvent('d',
          previous: DownloadState.idle, current: DownloadState.paused));
      dispose();
      emitter.emit(StateChangeEvent('d',
          previous: DownloadState.paused, current: DownloadState.downloading));
      expect(count, 1);
    });

    test('listener errors are contained and routed to onError', () {
      final emitter = EventEmitter();
      final errors = <Object>[];
      emitter.onError = (e, _) => errors.add(e);
      emitter.on((_) => throw StateError('boom'));
      var reached = false;
      emitter.on((_) => reached = true);
      emitter.emit(StateChangeEvent('d',
          previous: DownloadState.idle, current: DownloadState.downloading));
      expect(errors.length, 1);
      expect(reached, isTrue); // second listener still ran
    });

    test('pipeTo relays events to target', () {
      final source = EventEmitter();
      final target = EventEmitter();
      final relayed = <DownloadEvent>[];
      target.on(relayed.add);
      final dispose = source.pipeTo(target);
      source.emit(
          CompletedEvent('d', filename: 'f', totalBytes: 1, durationMs: 2));
      expect(relayed.length, 1);
      dispose();
      source.emit(
          CompletedEvent('d', filename: 'f', totalBytes: 1, durationMs: 2));
      expect(relayed.length, 1); // relay torn down
    });
  });
}
