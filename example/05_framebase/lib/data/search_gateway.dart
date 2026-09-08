import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

const archiveCollection = 'framebase_streets';
const archiveStream = 'street_study';

String firstText(Map<String, Object?> row, List<String> fields) {
  for (final field in fields) {
    final text = '${row[field] ?? ''}'.trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

String basename(String path) => path.replaceAll('\\', '/').split('/').last;

String hitFilename(Map<String, Object?> row) {
  final name = firstText(row, const [
    'filename',
    'filename_sanitized',
    'video_filename',
    'video',
    'source_path',
    'path',
    'title',
  ]);
  if (name.isNotEmpty) return basename(name);
  var id = firstText(row, const ['item_id']);
  final stream = firstText(row, const ['stream', 'stream_name']);
  final ts = firstText(row, const ['ts_unix', 'ts_unix_13digits']);
  if (stream.isNotEmpty && id.startsWith('$stream-')) {
    id = id.substring(stream.length + 1);
  }
  if (ts.isNotEmpty && id.endsWith('-$ts')) {
    id = id.substring(0, id.length - ts.length - 1);
  }
  return basename(id);
}

String timestamp13(Map<String, Object?> row) {
  final text = firstText(row, const [
    'ts_unix_13digits',
    'ts_unix',
    'timestamp_ms',
  ]);
  final value = num.tryParse(text);
  if (value == null || !value.isFinite || value < 0) return '';
  final digits = value.toInt().toString();
  if (digits.length >= 13) return digits.substring(0, 13);
  if (digits.length == 10) return '${value.toInt() * 1000}';
  return digits.padLeft(13, '0');
}

double? hitSeconds(Map<String, Object?> row) {
  for (final field in [
    'video_time_seconds',
    'timestamp_seconds',
    'time_seconds',
    'start_seconds',
    'offset_seconds',
    'seconds',
    'time_sec',
  ]) {
    final n = num.tryParse('${row[field]}');
    if (n != null && n.isFinite && n >= 0) return n.toDouble();
  }
  // The live video index returns zero-padded relative milliseconds in ts_unix.
  // Epoch values are deliberately not interpreted as playback positions.
  final ms = num.tryParse(
    firstText(row, const ['ts_unix_13digits', 'ts_unix', 'timestamp_ms']),
  );
  if (ms != null && ms.isFinite && ms >= 0 && ms < 86400000) return ms / 1000;
  return null;
}

class FrameMatch {
  const FrameMatch({
    required this.row,
    required this.filename,
    required this.timestamp,
    this.imageUrl,
    this.imageBytes,
    this.seconds,
  });
  final Map<String, Object?> row;
  final String filename;
  final String timestamp;
  final String? imageUrl;
  final Uint8List? imageBytes;
  final double? seconds;
  double? get distance => num.tryParse('${row['score']}')?.toDouble();
}

class SearchBatch {
  const SearchBatch({
    required this.matches,
    required this.total,
    required this.serverMs,
    required this.roundTripMs,
    required this.imageMs,
  });
  final List<FrameMatch> matches;
  final int total;
  final double serverMs;
  final int roundTripMs;
  final int imageMs;
}

/// One session, one application-owned collection. No credentials or signed URLs
/// are persisted. The low-level SDK is used consistently for collection selectors.
class SearchGateway {
  SearchGateway(String key, {VmodalTransport? transport})
    : keys = MutableApiKeyProvider(key) {
    client = VmodalClient(
      config: SdkConfig(
        apiKeyProvider: keys,
        timeout: const Duration(seconds: 60),
      ),
      transport: transport,
    );
  }

  final MutableApiKeyProvider keys;
  late final VmodalClient client;
  String accountId = '';
  int? version;

  Future<void> connect() async {
    final profile = await client.auth.me();
    if (profile.userId?.isNotEmpty != true) {
      throw const AuthException('No authenticated identity');
    }
    accountId = profile.userId!;
    await refreshVersion();
  }

  Future<void> refreshVersion() async {
    final groups = await client.collections.listGroups(mode: 'vid_file');
    version = groups
        .findGroup(archiveCollection, mode: 'vid_file')
        ?.latestLancedbVersion;
  }

  UploadTask<VideoUploadResponse> upload(File file) =>
      client.collections.videoUpload(
        UploadSource.fromFile(file),
        collectionName: archiveCollection,
        subCollectionName: archiveStream,
      );

  Future<IndexationSubmitResponse> createIndex(
    CancellationToken cancellation,
  ) => client.indexes.createIndex(
    IndexationSubmitRequest(
      mode: 'vid_file',
      groupName: archiveCollection,
      streamName: archiveStream,
      indexType: 'vid_img_emb',
      modality: 'vid_img_emb',
      reProcess: true,
    ),
    cancellation: cancellation,
  );

  Future<IndexationStatusResponse> indexStatus(
    String job,
    CancellationToken cancellation,
  ) => client.indexes.indexStatus(job, cancellation: cancellation);

  Future<SearchBatch> search(
    String query, {
    CancellationToken? cancellation,
    String? imageQuery,
    double maxDistance = 1.5,
  }) async {
    final token = cancellation ?? CancellationToken();
    final timer = Stopwatch()..start();
    final response = await client.searches.searchVideo(
      SearchRequest(
        queryText: query,
        imageQuery: imageQuery,
        mode: 'vid_file',
        groupName: archiveCollection,
        streamName: archiveStream,
        searchSources: const ['image'],
        limit: 30,
        imageEmbScoreMin: maxDistance,
        versionLancedb: version,
      ),
      cancellation: token,
    );
    final searchMs = timer.elapsedMilliseconds;
    final rows = response.data
        .whereType<Map>()
        .map((r) => r.map((k, v) => MapEntry('$k', v)))
        .toList();
    // Enforce the displayed cutoff defensively on returned rows as well.
    // A client-filtered result is distinct from the raw server result count.
    final usable = rows.where((r) {
      final distance = num.tryParse('${r['score']}');
      return hitFilename(r).isNotEmpty &&
          distance != null &&
          distance.isFinite &&
          distance <= maxDistance;
    }).toList();
    final urls = <int, String>{};
    final imageBytes = <int, Uint8List>{};
    if (usable.isNotEmpty) {
      final resolved = await client.images.getUrlBulk(
        usable
            .map(
              (row) => <String, Object?>{
                'mode': 'vid_file',
                'group_name': archiveCollection,
                'modality': 'vid_img',
                'stream_name':
                    firstText(row, const ['stream_name', 'stream']).isEmpty
                    ? archiveStream
                    : firstText(row, const ['stream_name', 'stream']),
                'filename': hitFilename(row),
                if (timestamp13(row).isNotEmpty)
                  'ts_unix_13digits': timestamp13(row),
              },
            )
            .toList(),
        cancellation: token,
      );
      for (var i = 0; i < resolved.records.length; i++) {
        final row = resolved.records[i];
        final rawIndex = row['input_index'];
        final parsed = num.tryParse('$rawIndex');
        final index = rawIndex == null
            ? i
            : parsed != null && parsed.isFinite && parsed == parsed.toInt()
            ? parsed.toInt()
            : null;
        final url = '${row['url_pre_signed'] ?? ''}';
        final uri = Uri.tryParse(url);
        final valid =
            uri != null &&
            (uri.scheme == 'https' ||
                (!uri.hasScheme &&
                    !uri.hasAuthority &&
                    uri.path == '/api/external/v1/image/get_image'));
        if (index != null &&
            index >= 0 &&
            index < usable.length &&
            row['found'] != false &&
            valid) {
          urls.putIfAbsent(index, () => url);
        }
      }
      // The beta gateway returns relative signed image routes. Its supported
      // image-byte resource resolves those without guessing an absolute origin.
      if (urls.isNotEmpty) {
        final downloaded = await client.images.getImageBulkFromUrls(
          urls.values.toList(),
          cancellation: token,
        );
        final byUrl = <String, Uint8List>{};
        for (final row in downloaded.records) {
          final url = '${row['url_pre_signed'] ?? ''}';
          final encoded = '${row['content_base64'] ?? ''}';
          if (url.isNotEmpty && encoded.isNotEmpty) {
            try {
              byUrl[url] = base64Decode(encoded);
            } on FormatException {
              /* Keep a per-card placeholder. */
            }
          }
        }
        for (final entry in urls.entries) {
          if (byUrl[entry.value] != null) {
            imageBytes[entry.key] = byUrl[entry.value]!;
          }
        }
      }
    }
    token.throwIfCanceled();
    return SearchBatch(
      matches: [
        for (var i = 0; i < usable.length; i++)
          FrameMatch(
            row: usable[i],
            filename: hitFilename(usable[i]),
            timestamp: timestamp13(usable[i]),
            imageUrl: urls[i]?.startsWith('https://') == true ? urls[i] : null,
            imageBytes: imageBytes[i],
            seconds: hitSeconds(usable[i]),
          ),
      ],
      total: response.cntTotal,
      serverMs: response.executionTimeMs,
      roundTripMs: searchMs,
      imageMs: timer.elapsedMilliseconds - searchMs,
    );
  }

  Future<void> close() async {
    keys.close();
    await client.close();
  }
}

bool indexDone(String state) => const {
  'success',
  'succeeded',
  'done',
  'completed',
  'ok',
}.contains(state.toLowerCase());
bool indexFailed(String state) => const {
  'failed',
  'failure',
  'error',
  'cancelled',
  'canceled',
}.contains(state.toLowerCase());
