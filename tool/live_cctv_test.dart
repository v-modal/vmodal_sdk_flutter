import 'dart:async';
import 'dart:io';

import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

Future<void> main() async {
  final env = Map<String, String>.from(Platform.environment);
  final client = await VmodalClient.fromEnvironment(
    env,
    resolveIdentity: false,
  );
  final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
  final group = 'sdk_flutter_cctv_$stamp';
  final videoName = 'camera_$stamp.mp4';
  final fixture = File(
    env['VMODAL_CCTV_FIXTURE'] ??
        'example/01_full_app/asset/video_10frames.mp4',
  );
  if (!fixture.existsSync()) {
    throw StateError('CCTV fixture does not exist: ${fixture.path}');
  }
  Object? primary;
  StackTrace? primaryStack;
  try {
    final upload = client.collections.videoUpload(
      UploadSource.fromFile(fixture),
      collectionName: group,
      subCollectionName: 'astream',
      options: VideoUploadOptions(
        videoFilename: videoName,
        metadataText: 'flutter cctv entrance',
        metadataTags: const <String>['flutter-cctv', 'entrance', 'tag3'],
        startDatetimeUser: '2026-07-30T09:15:00+09:00',
      ),
    );
    final uploaded = await upload.result.timeout(const Duration(minutes: 10));
    _expect(uploaded.videoFilename == videoName, 'video_filename mismatch');
    _expect(
      uploaded.startDatetimeUser == '2026-07-30T09:15:00+09:00',
      'start_datetime_user mismatch',
    );
    _expect(
      uploaded.startTsUnixUserMs == 1785370500000,
      'start_ts_unix_user_ms mismatch',
    );
    _expect(uploaded.timestampSource == 'user', 'timestamp_source mismatch');

    const startJst = '2026-07-30T09:15:00.000+09:00';
    const endJst = '2026-07-30T09:16:00.000+09:00';
    SearchResponse? ready;
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    while (DateTime.now().isBefore(deadline)) {
      ready = await _search(client, group, 'flutter-cctv', startJst, endJst);
      if (ready.cntActual > 0) break;
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    _expect(ready != null && ready.cntActual > 0, 'CCTV index was not ready');

    for (final query in <String>[
      'flutter cctv entrance',
      'flutter-cctv',
      'entrance',
      'tag3',
    ]) {
      final found = await _search(client, group, query, startJst, endJst);
      _expect(found.cntActual > 0, 'metadata query returned no hits: $query');
      for (final value in found.data) {
        final item = value! as Map<String, Object?>;
        _expect(
          '${item['item_id'] ?? ''}'.contains(videoName.split('.').first),
          'metadata query included a distractor item',
        );
      }
    }

    final narrow = await _search(
      client,
      group,
      'entrance',
      startJst,
      '2026-07-30T09:15:01.000+09:00',
    );
    _expect(narrow.cntActual > 0, 'narrow [start, end) range returned no hits');
    final before = await _search(
      client,
      group,
      'entrance',
      '2026-07-30T09:14:59.000+09:00',
      startJst,
    );
    _expect(before.cntActual == 0, 'pre-start range returned CCTV hits');
    final utc = await _search(
      client,
      group,
      'tag3',
      '2026-07-30T00:15:00.000Z',
      '2026-07-30T00:16:00.000Z',
    );
    _expect(
      utc.cntActual == ready!.cntActual,
      'UTC-equivalent range returned different results',
    );
    final missing = await _search(
      client,
      group,
      'metadata-that-does-not-exist',
      startJst,
      endJst,
    );
    _expect(missing.cntActual == 0, 'missing metadata returned hits');
    final wrongStream = await _search(
      client,
      group,
      'entrance',
      startJst,
      endJst,
      stream: 'wrong_stream',
    );
    _expect(wrongStream.cntActual == 0, 'wrong stream returned hits');
    stdout.writeln('live CCTV upload and absolute-time search OK');
  } on Object catch (error, stack) {
    primary = error;
    primaryStack = stack;
  } finally {
    try {
      await client.collections.delete(
        groupName: group,
        mode: 'vid_file',
        scope: 'all',
        confirm: true,
      );
    } on Object catch (error) {
      stderr.writeln('CCTV live cleanup failed: ${error.runtimeType}');
      primary ??= error;
      primaryStack ??= StackTrace.current;
    }
    await client.close();
  }
  if (primary != null) Error.throwWithStackTrace(primary, primaryStack!);
}

Future<SearchResponse> _search(
  VmodalClient client,
  String group,
  String metadata,
  String start,
  String end, {
  String stream = 'astream',
}) => client.searches.searchVideo(
  SearchRequest(
    queryText: 'visual',
    queryMetadataText: metadata,
    groupName: group,
    streamName: stream,
    searchSources: const <String>['image'],
    startDate: start,
    endDate: end,
    limit: 1000,
  ),
);

void _expect(bool value, String message) {
  if (!value) throw StateError(message);
}
