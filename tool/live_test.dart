import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

Future<void> main() async {
  final env = Map<String, String>.from(Platform.environment);
  final client = await VmodalClient.fromEnvironment(
    env,
    resolveIdentity: false,
  );
  final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
  final group = 'sdk_flutter_live_$stamp';
  Object? primary;
  StackTrace? primaryStack;
  Object? cleanup;
  try {
    final me = await client.auth.me();
    if ((me.userId ?? '').isEmpty) {
      throw StateError('auth.me returned no user_id');
    }
    await client.images.getUrl(
      mode: 'vid_file',
      groupName: group,
      modality: 'vid_img',
      filename: 'missing.mp4',
      tsUnix13digits: '0000000000000',
    );
    await client.images.getUrlBulk(<Map<String, Object?>>[
      <String, Object?>{
        'mode': 'vid_file',
        'group_name': group,
        'modality': 'vid_img',
        'stream_name': 'astream',
        'filename': 'missing.mp4',
        'ts_unix_13digits': '0000000000000',
      },
    ]);
    final bytes = base64Decode(_videoFixture);
    final upload = client.collections.videoUpload(
      UploadSource(
        fileName: 'flutter_live_$stamp.mp4',
        contentLength: bytes.length,
        contentType: 'video/mp4',
        sourceId: 'flutter-live-$stamp',
        opener: () => Stream<List<int>>.value(bytes),
      ),
      collectionName: group,
      subCollectionName: 'astream',
    );
    await upload.result.timeout(const Duration(minutes: 5));
    final job = await client.indexes.createIndex(
      IndexationSubmitRequest(
        mode: 'vid_file',
        groupName: group,
        streamName: 'astream',
        indexType: 'vid_img_emb',
        modality: 'vid_img_emb',
      ),
    );
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    var indexed = false;
    while (DateTime.now().isBefore(deadline)) {
      final status = await client.indexes.indexStatus(job.jobId);
      if (const <String>{
        'completed',
        'success',
        'done',
      }.contains(status.status)) {
        indexed = true;
        break;
      }
      if (const <String>{'failed', 'error'}.contains(status.status)) {
        final keys = status.raw.keys.toList()..sort();
        final code = status.raw['error_code']?.toString() ?? '';
        throw StateError('index job failed code=$code fields=$keys');
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    if (!indexed) {
      throw TimeoutException('index polling deadline');
    }
    final groups = await client.collections.listGroups(mode: 'vid_file');
    final version = groups
        .findGroup(group, mode: 'vid_file')
        ?.latestLancedbVersion;
    if (version == null) {
      throw StateError('indexed collection has no advertised LanceDB version');
    }
    await client.searches.searchVideo(
      SearchRequest(
        queryText: 'dummy video',
        groupName: group,
        streamName: 'astream',
        searchSources: const <String>['image'],
        versionLancedb: version,
      ),
    );
    stdout.writeln(
      'live lifecycle OK: auth, image smoke, signed upload, index, search',
    );
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
      cleanup ??= error;
    }
    try {
      final groups = await client.collections.listGroups(mode: 'vid_file');
      final stillPresent = groups.data.any(
        (Object? value) => value.toString().contains(group),
      );
      if (stillPresent) {
        cleanup ??= StateError('live collection still exists after cleanup');
      }
    } on Object catch (error) {
      cleanup ??= error;
    }
    await client.close();
  }
  if (primary != null) {
    Error.throwWithStackTrace(primary, primaryStack!);
  }
  if (cleanup != null) {
    throw StateError('live cleanup failed: ${cleanup.runtimeType}');
  }
}

const String _videoFixture =
    'AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAPbbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAB9AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAwZ0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAUAAAADwAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAfQAAAIAAABAAAAAAJ+bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAAUABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAACKW1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAelzdGJsAAAAwXN0c2QAAAAAAAAAAQAAALFhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAUAA8ABIAAAASAAAAAAAAAABFUxhdmM2Mi4xMS4xMDAgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAAN2F2Y0MBZAAW/+EAGmdkABascgRBQfsBEAAAAwAQAAADAUDxYthGAQAGaOhDjyyL/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAABCYAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAUAAAEAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAYGN0dHMAAAAAAAAACgAAAAEAAAgAAAAAAQAAKAAAAAABAAAQAAAAAAMAAAAAAAAABAAABAAAAAABAAAoAAAAAAEAABAAAAAAAwAAAAAAAAAEAAAEAAAAAAEAAAgAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAUAAAAAQAAAGRzdHN6AAAAAAAAAAAAAAAUAAAC9AAAABIAAAAPAAAADwAAAA8AAAAPAAAADwAAAA8AAAAPAAAADwAAABcAAAAPAAAADwAAAA8AAAAPAAAADwAAAA8AAAAPAAAADwAAABkAAAAUc3RjbwAAAAAAAAABAAAECwAAAGF1ZHRhAAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRvbwAAABxkYXRhAAAAAQAAAABMYXZmNjIuMy4xMDAAAAAIZnJlZQAABC5tZGF0AAACsAYF//+s3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTE2IGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDM6MHgxMzMgbWU9dW1oIHN1Ym1lPTEwIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MjQgY2hyb21hX21lPTEgdHJlbGxpcz0yIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9NyBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTggYl9weXJhbWlkPTIgYl9hZGFwdD0yIGJfYmlhcz0wIGRpcmVjdD0zIHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MiBrZXlpbnQ9MjUwIGtleWludF9taW49MTAgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD02MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAA8ZYiBAAJf/vet34FNwys1a7pXOLTLq5Q0PVH2lKZ4tkgAZAWL1EEVSG8c8qBJwAACoBSbLAQmU14sJJzPAAAADkGaCS2II//+tSqAAA5YAAAAC0GeEIcQQ/8AABHxAAAACwGeGCaIb/8AAFBAAAAACwGeGEaIb/8AAFBBAAAACwGeGGaIb/8AAFBBAAAACwGeGK1Ib/8AAFBBAAAACwGeGM1Ib/8AAFBBAAAACwGeGO1Ib/8AAFBAAAAACwGeGQ1Ib/8AAFBAAAAAE0GaGkk1AgLRMpgQ7/6plgAAb8EAAAALQZ4hpcQQ/wAAEfAAAAALAZ4pRaIb/wAAUEAAAAALAZ4pZaIb/wAAUEEAAAALAZ4phaIb/wAAUEEAAAALAZ4pzJIb/wAAUEEAAAALAZ4p7JIb/wAAUEAAAAALAZ4qDJIb/wAAUEAAAAALAZ4qLJIb/wAAUEEAAAAVQZoqabUCAtrRMpgBDf/+p4QAAN6A';
