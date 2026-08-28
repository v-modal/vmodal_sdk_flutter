# Mobile performance and memory

The SDK streams signed upload bodies and file ranges. A bulk task uses one
signed-PUT budget across every file and multipart part, so
`VideoUploadOptions.maxConcurrency` is a task ceiling rather than a nested
multiplier. Progress is monotonic and coalesced at a 1% byte advance or 250 ms,
with the final non-empty 100% event always delivered.

`SdkConfig.timeout` bounds request setup and each signed-upload phase.
`SdkConfig.idleTimeout` bounds silence while an API response body is consumed;
it defaults to `timeout`. A retryable GET uses a fresh attempt cancellation token,
so an attempt timeout does not cancel the caller's token. POST and multipart
operations are never automatically replayed after a body timeout.

## Bounded image persistence

`getImageFromUrl` still returns `Uint8List`. Set `maxBytes` to a positive value
no larger than the SDK's 64 MiB binary ceiling when the caller needs a smaller
limit. To avoid a second in-memory image buffer, stream into a caller-owned sink:

```dart
final sink = cacheFile.openWrite();
await client.images.writeImageFromUrl(url, sink, maxBytes: 8 * 1024 * 1024);
await sink.close();
```

The SDK awaits the stream but does not close that sink. Use
`saveImageFromUrl(url, file, maxBytes: ...)` when the SDK should own the file
sink. It writes a unique sibling temporary file and renames it only after a
complete bounded response, leaving an existing destination unchanged on error.

## Native control clients

Cronet and Cupertino remain application dependencies, not SDK defaults. A
native `package:http` client can be injected through the public transport:

```dart
final config = SdkConfig(token: runtimeApiKey);
final transport = HttpVmodalTransport(config, client: appOwnedNativeClient);
final client = VmodalClient(config: config, transport: transport);
```

Use a client instance dedicated to that `VmodalClient`; closing the SDK client
closes its supplied transports. Native clients affect control requests only.
Signed media PUTs continue through `SignedUploadTransport`, whose integrity,
cancellation, timeout, redirect, and header rules must be preserved by any
custom adapter.

## Benchmark harness

Run the throttled local harness from the package root:

```bash
dart run tool/perf_benchmark.dart --sizes=5,64,100 --delay-ms=1
```

It reports JSON lines for single and bulk multipart runs: wall time, MiB/s,
peak/current RSS growth, UI progress events, signed PUT count/bytes, and maximum
active signed PUTs. Desktop results catch regressions but do not substitute for
profile/release measurements on at least one mid-range Android device and one
iPhone. Compare the default `http.Client` with a caller-injected native client
in the application that owns the platform dependency; do not change the SDK
default without device evidence.
