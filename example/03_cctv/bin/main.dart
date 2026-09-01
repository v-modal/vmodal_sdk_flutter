import 'dart:io';

import 'package:vmodal_cctv_example/cctv_example.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

Future<void> main(List<String> args) async {
  if (args.length < 4) {
    stderr.writeln(
      'Usage: dart run bin/main.dart VIDEO_PATH VIDEO_FILENAME '
      'START_DATETIME END_DATETIME',
    );
    stderr.writeln(
      'Example: dart run bin/main.dart camera.mp4 entrance_001.mp4 '
      '2026-07-30T09:15:00+09:00 2026-07-30T09:16:00+09:00',
    );
    exitCode = 2;
    return;
  }
  final apiKey = Platform.environment['VMODAL_API_KEY'] ?? '';
  if (apiKey.isEmpty) {
    stderr.writeln('VMODAL_API_KEY is required.');
    exitCode = 2;
    return;
  }

  final keys = MutableApiKeyProvider(apiKey);
  final example = CctvExample(apiKeyProvider: keys);
  final input = CctvUploadInput(
    file: File(args[0]),
    videoFilename: args[1],
    startDatetimeUser: args[2],
    metadataText: 'Entrance camera during opening hours',
    metadataTags: const <String>['cctv', 'entrance', 'camera_01'],
  );

  try {
    stdout.writeln('1. Authenticate');
    final profile = await example.authenticate();
    stdout.writeln('   authenticated type=${profile.type}');

    stdout.writeln('2. List collections');
    final collections = await example.listCollections();
    stdout.writeln('   collections=$collections');

    stdout.writeln('3. List index jobs');
    final jobs = await example.listIndexJobs();
    stdout.writeln('   index_jobs=${jobs.total}');

    stdout.writeln('4. Upload timestamped CCTV video');
    final uploaded = await example.upload(input).result;
    stdout.writeln(
      '   video=${uploaded.videoFilename} '
      'start_ms=${uploaded.startTsUnixUserMs} '
      'source=${uploaded.timestampSource}',
    );

    stdout.writeln('5. Create and wait for the frame index');
    final job = await example.createIndex();
    final status = await example.waitForIndex(job.jobId);
    stdout.writeln('   job=${job.jobId} status=${status.status}');

    stdout.writeln('6. Search metadata inside an absolute time range');
    final found = await example.search(
      CctvSearchInput(
        visualQuery: 'a person entering the building',
        metadataQuery: 'entrance',
        startDate: args[2],
        endDate: args[3],
      ),
    );
    stdout.writeln('   matches=${found.cntActual}');
  } finally {
    keys.clear();
    await example.close();
  }
}
