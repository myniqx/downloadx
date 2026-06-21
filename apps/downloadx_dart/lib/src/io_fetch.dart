import 'io.dart';

/// Signature of a WHATWG-`fetch`-style function. A method tear-off of
/// [DownloadxIo.fetch] satisfies it, and tests pass a standalone mock.
typedef FetchFn = Future<FetchResponse> Function(String url, [FetchInit? init]);
