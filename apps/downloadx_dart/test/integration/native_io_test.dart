@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

import '../helpers/mock_io.dart';

/// Exercises the real `dart:io` [NativeIo] (HttpClient + random-access disk
/// writes) against a local, range-capable HTTP server. No external network.
void main() {
  late HttpServer server;
  late Uint8List body;
  late String baseUrl;
  late Directory tmp;

  setUp(() async {
    body = deterministicBytes(50000);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}/file.bin';
    server.listen((req) async {
      final res = req.response;
      res.headers.set('etag', '"v1"');
      res.headers.set('accept-ranges', 'bytes');
      if (req.method == 'HEAD') {
        res.headers.contentLength = body.length;
        await res.close();
        return;
      }
      final range = req.headers.value('range');
      if (range != null) {
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
        final start = int.parse(m.group(1)!);
        final endStr = m.group(2)!;
        final end = endStr.isEmpty ? body.length - 1 : int.parse(endStr);
        final slice = Uint8List.sublistView(body, start, end + 1);
        res.statusCode = HttpStatus.partialContent;
        res.headers.set('content-range', 'bytes $start-$end/${body.length}');
        res.headers.contentLength = slice.length;
        res.add(slice);
      } else {
        res.headers.contentLength = body.length;
        res.add(body);
      }
      await res.close();
    });

    tmp = await Directory.systemTemp.createTemp('downloadx_native_');
  });

  tearDown(() async {
    await server.close(force: true);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('downloads a real file through NativeIo and assembles it byte-exact',
      () async {
    final manager = await createDownloadX(DownloadXConfig(
      // io defaults to NativeIo — real disk + HttpClient.
      targetPath: tmp.path,
      maxParallel: 2,
      targetChunkCount: 4,
      minChunkSize: 4096,
      requestTimeout: 10000,
    ));

    final dl = await manager.addUrl(baseUrl);
    await dl.start();

    expect(dl.state, DownloadState.completed);
    final out = File('${tmp.path}/file.bin');
    expect(await out.exists(), isTrue);
    final written = await out.readAsBytes();
    expect(written.length, body.length);
    expect(written, equals(body));
  });

  test('resumes a partially-written file on a fresh manager', () async {
    // First run: start then pause quickly (may race to completion).
    final m1 = await createDownloadX(DownloadXConfig(
      targetPath: tmp.path,
      cachePath: tmp.path,
      targetChunkCount: 4,
      minChunkSize: 4096,
      speedLimit: 200000,
      requestTimeout: 10000,
    ));
    final d1 = await m1.addUrl(baseUrl, const DownloadOptions(id: 'fixed'));
    final run = d1.start();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    d1.pause();
    await run;

    // Second manager restores from the same cache dir and finishes the job.
    final m2 = await createDownloadX(DownloadXConfig(
      targetPath: tmp.path,
      cachePath: tmp.path,
      targetChunkCount: 4,
      minChunkSize: 4096,
      requestTimeout: 10000,
    ));
    final d2 = m2.getDownload('fixed')!;
    await d2.start();

    expect(d2.state, DownloadState.completed);
    final written = await File('${tmp.path}/file.bin').readAsBytes();
    expect(written, equals(body));
  });
}
