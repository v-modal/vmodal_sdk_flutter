import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_cctv_example/cctv_example.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

void main() {
  test(
    'CCTV input maps every new upload field without caller-list mutation',
    () {
      final tags = <String>['cctv', 'entrance', 'camera_01'];
      final input = CctvUploadInput(
        file: File('camera.mp4'),
        videoFilename: 'entrance_001.mp4',
        startDatetimeUser: '2026-07-30T09:15:00+09:00',
        metadataText: 'Entrance camera during opening hours',
        metadataTags: tags,
        reProcess: true,
      );
      tags.add('changed-after-construction');
      final options = input.toUploadOptions();

      expect(options.videoFilename, 'entrance_001.mp4');
      expect(options.startDatetimeUser, '2026-07-30T09:15:00+09:00');
      expect(options.metadataText, 'Entrance camera during opening hours');
      expect(options.metadataTags, <String>['cctv', 'entrance', 'camera_01']);
      expect(options.reProcess, isTrue);
    },
  );

  test('CCTV search maps metadata and offset-aware absolute time bounds', () {
    const input = CctvSearchInput(
      visualQuery: 'a person entering the building',
      metadataQuery: 'entrance',
      startDate: '2026-07-30T09:15:00+09:00',
      endDate: '2026-07-30T09:16:00+09:00',
      versionLancedb: 2,
    );
    final options = input.toSearchOptions();

    expect(options.queryMetadataText, 'entrance');
    expect(options.searchSources, <String>['image']);
    expect(options.startDate, '2026-07-30T09:15:00+09:00');
    expect(options.endDate, '2026-07-30T09:16:00+09:00');
    expect(options.versionLancedb, 2);
  });

  test('CCTV example exposes the progressive project and camera scope', () {
    final example = CctvExample(
      apiKeyProvider: MutableApiKeyProvider('runtime-key'),
    );
    addTearDown(example.close);

    expect(example.projectId, 'cctv_app');
    expect(example.collectionName, 'entrance_cameras');
    expect(example.streamName, 'camera_01');
    expect(example.camera.projectId, 'cctv_app');
    expect(example.camera.collectionName, 'entrance_cameras');
    expect(example.camera.streamName, 'camera_01');
    expect(example.authenticate, isA<Future<UserProfile> Function()>());
    expect(example.listCollections, isA<Future<List<String>> Function()>());
    expect(
      example.listIndexJobs,
      isA<Future<IndexationJobsListResponse> Function()>(),
    );
  });
}
