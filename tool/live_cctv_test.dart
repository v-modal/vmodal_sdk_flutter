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
    final uploaded = await client.collections.uploadFile(
      filePart('file', fixture),
      groupName: group,
      streamName: 'astream',
      videoFilename: videoName,
      metadataText: 'flutter cctv entrance',
      metadataTags: const <String>['flutter-cctv', 'entrance', 'tag3'],
      startDatetimeUser: '2026-07-30T09:15:00+09:00',
    );
    _expect(
      uploaded.raw['video_filename'] == videoName,
      'video_filename mismatch',
    );
    _expect(
      uploaded.raw['start_datetime_user'] == '2026-07-30T09:15:00+09:00',
      'start_datetime_user mismatch',
    );
    _expect(
      '${uploaded.raw['start_ts_unix_user_ms']}' == '1785370500000',
      'start_ts_unix_user_ms mismatch',
    );
    _expect(
      uploaded.raw['timestamp_source'] == 'user',
      'timestamp_source mismatch',
    );

    final job = await client.indexes.createIndex(
      IndexationSubmitRequest(
        mode: 'vid_file',
        groupName: group,
        streamName: 'astream',
        indexType: 'vid_img_emb',
        modality: 'vid_img_emb',
      ),
    );
    await _waitForIndex(client, job.jobId);
    final groups = await client.collections.listGroups(mode: 'vid_file');
    final version = groups
        .findGroup(group, mode: 'vid_file')
        ?.latestLancedbVersion;
    if (version == null) {
      throw StateError('indexed CCTV collection has no LanceDB version');
    }

    const startJst = '2026-07-30T09:15:00.000+09:00';
    const endJst = '2026-07-30T09:16:00.000+09:00';
    final base = await _searchBase(client, group, version);
    stdout.writeln(
      'CCTV base search: count=${base.cntActual} '
      'timestamps=${base.data.map((value) => (value! as Map<String, Object?>)['ts_unix']).toList()}',
    );
    final dated = await _searchBase(
      client,
      group,
      version,
      start: startJst,
      end: endJst,
    );
    stdout.writeln('CCTV absolute-time search: count=${dated.cntActual}');
    final tagged = await _searchBase(
      client,
      group,
      version,
      metadata: 'flutter-cctv',
    );
    stdout.writeln('CCTV metadata search: count=${tagged.cntActual}');
    SearchResponse? ready;
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(deadline)) {
      ready = await _search(
        client,
        group,
        'flutter-cctv',
        startJst,
        endJst,
        version: version,
      );
      if (ready.cntActual > 0) break;
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    _expect(
      ready != null && ready.cntActual > 0,
      'CCTV metadata search returned no indexed hits',
    );

    for (final query in <String>[
      'flutter cctv entrance',
      'flutter-cctv',
      'entrance',
      'tag3',
    ]) {
      final found = await _search(
        client,
        group,
        query,
        startJst,
        endJst,
        version: version,
      );
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
      version: version,
    );
    _expect(narrow.cntActual > 0, 'narrow [start, end) range returned no hits');
    final before = await _search(
      client,
      group,
      'entrance',
      '2026-07-30T09:14:59.000+09:00',
      startJst,
      version: version,
    );
    _expect(before.cntActual == 0, 'pre-start range returned CCTV hits');
    final utc = await _search(
      client,
      group,
      'tag3',
      '2026-07-30T00:15:00.000Z',
      '2026-07-30T00:16:00.000Z',
      version: version,
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
      version: version,
    );
    _expect(missing.cntActual == 0, 'missing metadata returned hits');
    final wrongStream = await _search(
      client,
      group,
      'entrance',
      startJst,
      endJst,
      stream: 'wrong_stream',
      version: version,
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
  required int version,
}) => client.searches.searchVideo(
  SearchRequest(
    queryText: 'pink and cyan diagonal stripes',
    queryMetadataText: metadata,
    groupName: group,
    streamName: stream,
    searchSources: const <String>['image'],
    startDate: start,
    endDate: end,
    limit: 1000,
    versionLancedb: version,
  ),
);

Future<SearchResponse> _searchBase(
  VmodalClient client,
  String group,
  int version, {
  String? metadata,
  String? start,
  String? end,
}) => client.searches.searchVideo(
  SearchRequest(
    queryText: 'pink and cyan diagonal stripes',
    queryMetadataText: metadata,
    groupName: group,
    streamName: 'astream',
    searchSources: const <String>['image'],
    startDate: start,
    endDate: end,
    limit: 1000,
    versionLancedb: version,
  ),
);

Future<void> _waitForIndex(VmodalClient client, String jobId) async {
  final deadline = DateTime.now().add(const Duration(minutes: 10));
  while (DateTime.now().isBefore(deadline)) {
    final status = await client.indexes.indexStatus(jobId);
    if (const <String>{
      'completed',
      'success',
      'done',
    }.contains(status.status)) {
      return;
    }
    if (const <String>{'failed', 'error'}.contains(status.status)) {
      final code = status.raw['error_code']?.toString() ?? '';
      throw StateError('CCTV index job failed code=$code');
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  throw TimeoutException('CCTV index polling deadline');
}

void _expect(bool value, String message) {
  if (!value) throw StateError(message);
}
