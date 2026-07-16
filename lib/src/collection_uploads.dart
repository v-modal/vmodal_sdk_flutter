import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'adaptive_upload.dart';
import 'errors.dart';
import 'models.dart';
import 'resources.dart';
import 'routes.dart';
import 'transport.dart';
import 'upload.dart';
import 'utils.dart';

class VideoUploadOptions {
  const VideoUploadOptions({
    this.multipart = false,
    this.multipartThresholdBytes = 100 * 1024 * 1024,
    this.partSizeBytes = 64 * 1024 * 1024,
    this.maxConcurrency = 4,
    this.maxPartAttempts = 5,
    this.partTimeout = const Duration(seconds: 300),
    this.resume = true,
    this.sessionStore,
    this.adaptiveConditions,
  });

  final bool multipart;
  final int multipartThresholdBytes;
  final int partSizeBytes;
  final int maxConcurrency;
  final int maxPartAttempts;
  final Duration partTimeout;
  final bool resume;
  final UploadSessionStore? sessionStore;
  final UploadConditions? adaptiveConditions;

  UploadSessionStore get store => sessionStore ?? UploadSessionStores.memory;

  VideoUploadOptions resolvedFor(int size) {
    if (!multipart || adaptiveConditions == null) return this;
    final preset = AdaptiveUploadPolicy.select(size, adaptiveConditions!);
    return copyWith(
      partSizeBytes: preset.partSizeBytes,
      maxConcurrency: preset.maxConcurrency,
      maxPartAttempts: preset.maxPartAttempts,
      partTimeout: preset.partTimeout,
    );
  }

  VideoUploadOptions copyWith({
    bool? multipart,
    int? multipartThresholdBytes,
    int? partSizeBytes,
    int? maxConcurrency,
    int? maxPartAttempts,
    Duration? partTimeout,
    bool? resume,
    UploadSessionStore? sessionStore,
    UploadConditions? adaptiveConditions,
  }) => VideoUploadOptions(
    multipart: multipart ?? this.multipart,
    multipartThresholdBytes:
        multipartThresholdBytes ?? this.multipartThresholdBytes,
    partSizeBytes: partSizeBytes ?? this.partSizeBytes,
    maxConcurrency: maxConcurrency ?? this.maxConcurrency,
    maxPartAttempts: maxPartAttempts ?? this.maxPartAttempts,
    partTimeout: partTimeout ?? this.partTimeout,
    resume: resume ?? this.resume,
    sessionStore: sessionStore ?? this.sessionStore,
    adaptiveConditions: adaptiveConditions ?? this.adaptiveConditions,
  );

  void validate(int size) {
    if (!multipart) return;
    if (partSizeBytes < 5 * 1024 * 1024) {
      throw const ValidationException('part_size_bytes must be at least 5 MiB');
    }
    if (maxConcurrency < 1 || maxConcurrency > 16) {
      throw const ValidationException('max_concurrency must be in 1..16');
    }
    if (maxPartAttempts < 1 || maxPartAttempts > 10) {
      throw const ValidationException('max_part_attempts must be in 1..10');
    }
    if (partTimeout <= Duration.zero) {
      throw const ValidationException('part_timeout must be positive');
    }
    if (size <= 0) {
      throw const ValidationException('multipart size must be positive');
    }
    if (_partCount(size, partSizeBytes) > 10000) {
      throw const ValidationException(
        'part_size_bytes would create more than 10,000 parts',
      );
    }
  }
}

extension CollectionUploads on CollectionsResource {
  UploadTask<VideoUploadResponse> videoUpload(
    UploadSource source, {
    required String collectionName,
    required String subCollectionName,
    String mode = 'vid_file',
    String modality = 'vid_raw',
    int ttl = 12600,
    VideoUploadOptions options = const VideoUploadOptions(),
  }) {
    final resolved = options.resolvedFor(source.contentLength);
    resolved.validate(source.contentLength);
    return UploadTask<VideoUploadResponse>.start(
      (CancellationToken cancellation, void Function(UploadProgress) emit) =>
          _videoUploadRun(
            source,
            collectionName,
            subCollectionName,
            mode,
            modality,
            ttl,
            resolved,
            cancellation,
            emit,
          ),
    );
  }

  UploadTask<VideoUploadBulkResponse> videoUploadBulk(
    List<UploadSource> sources, {
    required String collectionName,
    required String subCollectionName,
    String mode = 'vid_file',
    String modality = 'vid_raw',
    int ttl = 12600,
    VideoUploadOptions options = const VideoUploadOptions(),
  }) {
    final resolved = sources
        .map((UploadSource source) => options.resolvedFor(source.contentLength))
        .toList();
    for (var i = 0; i < sources.length; i++) {
      resolved[i].validate(sources[i].contentLength);
    }
    return UploadTask<VideoUploadBulkResponse>.start((
      CancellationToken cancellation,
      void Function(UploadProgress) emit,
    ) async {
      if (sources.isEmpty) {
        return VideoUploadBulkResponse(const <String, Object?>{
          'data': <Object?>[],
          'total': 0,
        });
      }
      final total = sources.fold<int>(
        0,
        (int value, UploadSource source) => value + source.contentLength,
      );
      final sent = List<int>.filled(sources.length, 0);
      final results = List<VideoUploadResponse?>.filled(sources.length, null);
      var cursor = 0;
      Object? firstError;
      StackTrace? firstStack;
      Future<void> worker() async {
        while (!cancellation.isCanceled && firstError == null) {
          final index = cursor++;
          if (index >= sources.length) return;
          try {
            results[index] = await _videoUploadRun(
              sources[index],
              collectionName,
              subCollectionName,
              mode,
              modality,
              ttl,
              resolved[index],
              cancellation,
              (UploadProgress progress) {
                sent[index] = max(sent[index], progress.uploadedBytes);
                emit(
                  UploadProgress(
                    sent.fold<int>(0, (int a, int b) => a + b),
                    total,
                  ),
                );
              },
            );
            sent[index] = sources[index].contentLength;
          } on Object catch (error, stack) {
            firstError ??= error;
            firstStack ??= stack;
            cancellation.cancel();
          }
        }
      }

      final concurrency = options.maxConcurrency.clamp(1, sources.length);
      await Future.wait(
        List<Future<void>>.generate(concurrency, (_) => worker()),
      );
      if (firstError != null) {
        Error.throwWithStackTrace(firstError!, firstStack!);
      }
      cancellation.throwIfCanceled();
      final data = results.cast<VideoUploadResponse>();
      return VideoUploadBulkResponse(<String, Object?>{
        'data': data.map((VideoUploadResponse item) => item.raw).toList(),
        'total': data.length,
      });
    });
  }

  Future<VideoUploadResponse> _videoUploadRun(
    UploadSource source,
    String collection,
    String stream,
    String mode,
    String modality,
    int ttl,
    VideoUploadOptions options,
    CancellationToken cancellation,
    void Function(UploadProgress) emit,
  ) async {
    if (!options.multipart) {
      return _singleUpload(
        source,
        collection,
        stream,
        mode,
        modality,
        ttl,
        cancellation,
        emit,
      );
    }
    try {
      return await _multipartUpload(
        source,
        collection,
        stream,
        mode,
        modality,
        ttl,
        options,
        cancellation,
        emit,
      );
    } on ApiException catch (error) {
      if (error.statusCode != 404) rethrow;
      throw const FeatureDisabled(
        'experimental multipart upload is unavailable on this gateway; '
        'retry with VideoUploadOptions(multipart: false)',
      );
    }
  }

  Future<VideoUploadResponse> _singleUpload(
    UploadSource source,
    String collection,
    String stream,
    String mode,
    String modality,
    int ttl,
    CancellationToken cancellation,
    void Function(UploadProgress) emit,
  ) async {
    cancellation.throwIfCanceled();
    final signed = await http.request(
      'POST',
      Routes.full(Routes.externalUploadGetSignedUrl),
      params: _uploadParams(source, collection, stream, mode, modality, ttl),
      cancellation: cancellation,
    );
    cancellation.throwIfCanceled();
    final url = _signedUri('${signed['url'] ?? ''}');
    final result = await signedUploads.upload(
      source: source,
      url: url,
      method: '${signed['method'] ?? 'PUT'}',
      cancellation: cancellation,
      onProgress: emit,
    );
    cancellation.throwIfCanceled();
    final done = await _uploadDone(
      '${signed['key'] ?? ''}',
      source,
      collection,
      stream,
      mode,
      modality,
      cancellation,
    );
    return VideoUploadResponse(<String, Object?>{
      ...signed,
      'filename': source.fileName,
      'size_bytes': source.contentLength,
      'status_code': result.statusCode,
      'uploaded': true,
      'upload_strategy': 'single',
      'etag': result.etag,
      'part_count': 1,
      'parts_uploaded': 1,
      'attempt_count': 1,
      'upload_done': done,
      'dest_path': '${done['dest_path'] ?? ''}',
    });
  }

  Future<VideoUploadResponse> _multipartUpload(
    UploadSource source,
    String collection,
    String stream,
    String mode,
    String modality,
    int ttl,
    VideoUploadOptions options,
    CancellationToken cancellation,
    void Function(UploadProgress) emit,
  ) async {
    final contract = _UploadContract(
      source: source,
      baseUrl: http.config.normalizedBaseUrl,
      userId: http.config.normalizedUserId,
      collection: collection,
      stream: stream,
      mode: mode,
      modality: modality,
      partSize: options.partSizeBytes,
    );
    final sessionKey = contract.key;
    final storedRaw = await options.store.load(sessionKey);
    var session = storedRaw == null
        ? null
        : _MultipartSession.fromJson(storedRaw, contract);
    if (!options.resume && session != null) {
      await _multipartAbort(session, cancellation);
      await options.store.remove(sessionKey);
      session = null;
    }
    var resumed = session != null;
    session ??= await _multipartCreate(contract, cancellation);
    await options.store.save(sessionKey, session.toJson(contract));

    Map<String, Object?> status;
    try {
      status = await _multipartStatus(session, cancellation);
    } on ApiException catch (error) {
      if (error.statusCode != 404) rethrow;
      await options.store.remove(sessionKey);
      session = await _multipartCreate(contract, cancellation);
      await options.store.save(sessionKey, session.toJson(contract));
      resumed = false;
      status = await _multipartStatus(session, cancellation);
    }
    if ('${status['status']}' == 'completed') {
      final etag = '${status['etag'] ?? ''}';
      if (intValue(status['size_bytes']) != source.contentLength ||
          etag.isEmpty) {
        throw const ApiException(
          'completed multipart status does not match local upload contract',
        );
      }
      final done = await _uploadDone(
        session.key,
        source,
        collection,
        stream,
        mode,
        modality,
        cancellation,
      );
      await options.store.remove(sessionKey);
      return _multipartResponse(source, session, etag, resumed, 0, done);
    }

    final remote = objectList(status['parts']);
    final numbers = remote
        .map((Map<String, Object?> row) => intValue(row['part_number']))
        .toList();
    if (numbers.toSet().length != numbers.length ||
        numbers.any((int value) => value < 1 || value > session!.partCount)) {
      throw const ApiException(
        'multipart status returned duplicate or out-of-range parts',
      );
    }
    final valid = <int, Map<String, Object?>>{};
    for (final part in remote) {
      final number = intValue(part['part_number']);
      final length = _partLength(
        source.contentLength,
        session.partSize,
        number,
      );
      if (intValue(part['size_bytes']) != length) continue;
      final expected =
          session.partMd5[number] ??
          await md5Hex(
            source,
            offset: (number - 1) * session.partSize,
            length: length,
          );
      if ('${part['etag'] ?? ''}'.toLowerCase() == expected.toLowerCase()) {
        valid[number] = part;
        session.partMd5[number] = expected;
      }
    }
    await options.store.save(sessionKey, session.toJson(contract));
    final sentByPart = <int, int>{
      for (final entry in valid.entries)
        entry.key: intValue(entry.value['size_bytes']),
    };
    var lastProgress = 0;
    void report() {
      final total = sentByPart.values
          .fold<int>(0, (int a, int b) => a + b)
          .clamp(0, source.contentLength);
      lastProgress = max(lastProgress, total);
      emit(UploadProgress(lastProgress, source.contentLength));
    }

    if (sentByPart.isNotEmpty) report();
    final missing = <int>[
      for (var number = 1; number <= session.partCount; number++)
        if (!valid.containsKey(number)) number,
    ];
    var attempts = 0;
    for (
      var start = 0;
      start < missing.length;
      start += max(1, options.maxConcurrency * 2)
    ) {
      cancellation.throwIfCanceled();
      final batch = missing.sublist(
        start,
        min(missing.length, start + max(1, options.maxConcurrency * 2)),
      );
      final signedRaw = await _multipartSign(session, batch, ttl, cancellation);
      final signed = <int, Map<String, Object?>>{
        for (final row in objectList(signedRaw['parts']))
          intValue(row['part_number']): row,
      };
      if (signed.length != batch.length ||
          !signed.keys.toSet().containsAll(batch)) {
        throw const ApiException(
          'multipart sign response did not match requested parts',
        );
      }
      var cursor = 0;
      final uploaded = <_UploadedPart>[];
      Object? firstError;
      StackTrace? firstStack;
      Future<void> worker() async {
        while (firstError == null && !cancellation.isCanceled) {
          final index = cursor++;
          if (index >= batch.length) return;
          final number = batch[index];
          try {
            final part = await _multipartPutOne(
              source,
              session!,
              number,
              signed[number]!,
              ttl,
              options,
              cancellation,
              (UploadProgress progress) {
                sentByPart[number] = max(
                  sentByPart[number] ?? 0,
                  progress.uploadedBytes,
                );
                report();
              },
            );
            uploaded.add(part);
          } on Object catch (error, stack) {
            firstError ??= error;
            firstStack ??= stack;
          }
        }
      }

      await Future.wait(
        List<Future<void>>.generate(
          min(options.maxConcurrency, batch.length),
          (_) => worker(),
        ),
      );
      if (firstError != null) {
        Error.throwWithStackTrace(firstError!, firstStack!);
      }
      for (final part in uploaded) {
        attempts += part.attempts;
        session.partMd5[part.number] = part.md5;
        sentByPart[part.number] = part.size;
      }
      await options.store.save(sessionKey, session.toJson(contract));
      report();
    }

    cancellation.throwIfCanceled();
    status = await _multipartStatus(session, cancellation);
    final parts = _multipartFinalParts(session, source.contentLength, status);
    final complete = await http.request(
      'POST',
      Routes.full(Routes.externalUploadMultipartComplete),
      json: <String, Object?>{
        'request_id': session.requestId,
        'upload_id': session.uploadId,
        'key': session.key,
        'size_bytes': source.contentLength,
        'parts': parts,
      },
      cancellation: cancellation,
    );
    final etag = '${complete['etag'] ?? ''}';
    if (etag.isEmpty) {
      throw const ApiException('multipart complete response returned no ETag');
    }
    cancellation.throwIfCanceled();
    final done = await _uploadDone(
      session.key,
      source,
      collection,
      stream,
      mode,
      modality,
      cancellation,
    );
    await options.store.remove(sessionKey);
    emit(UploadProgress(source.contentLength, source.contentLength));
    return _multipartResponse(source, session, etag, resumed, attempts, done);
  }

  Future<_MultipartSession> _multipartCreate(
    _UploadContract contract,
    CancellationToken cancellation,
  ) async {
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final raw = await http.request(
      'POST',
      Routes.full(Routes.externalUploadMultipartCreate),
      json: <String, Object?>{
        'request_id': requestId,
        'mode': contract.mode,
        'group_name': contract.collection,
        'stream_name': contract.stream,
        'modality': contract.modality,
        'filename': contract.source.fileName,
        'content_type': contract.source.contentType,
        'size_bytes': contract.source.contentLength,
        'part_size_bytes': contract.partSize,
      },
      cancellation: cancellation,
    );
    final session = _MultipartSession(
      requestId: '${raw['request_id'] ?? requestId}',
      uploadId: '${raw['upload_id'] ?? ''}',
      key: '${raw['key'] ?? ''}',
      partCount: intValue(raw['part_count']),
      partSize: intValue(raw['part_size_bytes']),
    );
    final expected = _partCount(
      contract.source.contentLength,
      contract.partSize,
    );
    if (session.uploadId.isEmpty ||
        session.key.isEmpty ||
        session.partCount != expected ||
        session.partSize != contract.partSize) {
      throw const ApiException(
        'multipart create response does not match local upload contract',
      );
    }
    return session;
  }

  Future<_UploadedPart> _multipartPutOne(
    UploadSource source,
    _MultipartSession session,
    int number,
    Map<String, Object?> signed,
    int ttl,
    VideoUploadOptions options,
    CancellationToken cancellation,
    void Function(UploadProgress) emit,
  ) async {
    final offset = (number - 1) * session.partSize;
    final length = _partLength(source.contentLength, session.partSize, number);
    var item = signed;
    for (var attempt = 1; attempt <= options.maxPartAttempts; attempt++) {
      cancellation.throwIfCanceled();
      try {
        final headers = objectMap(
          item['headers'],
        ).map((String key, Object? value) => MapEntry(key, '$value'));
        final result = await signedUploads.upload(
          source: source,
          url: _signedUri('${item['url'] ?? ''}'),
          method: '${item['method'] ?? 'PUT'}',
          offset: offset,
          length: length,
          headers: headers,
          timeout: options.partTimeout,
          cancellation: cancellation,
          onProgress: emit,
        );
        final expected = result.localMd5.isEmpty
            ? await md5Hex(source, offset: offset, length: length)
            : result.localMd5;
        if (result.etag.isEmpty ||
            result.etag.toLowerCase() != expected.toLowerCase()) {
          throw ApiException(
            'multipart part ETag mismatch',
            body: <String, Object?>{'part_number': number},
          );
        }
        return _UploadedPart(number, result.etag, length, expected, attempt);
      } on Object catch (error) {
        cancellation.throwIfCanceled();
        final localMd5 =
            error is SignedUploadFailure && error.localMd5.isNotEmpty
            ? error.localMd5
            : await md5Hex(source, offset: offset, length: length);
        final found = await _multipartReconcilePart(
          session,
          number,
          length,
          localMd5,
          cancellation,
        );
        if (found != null) {
          return _UploadedPart(number, found, length, localMd5, attempt);
        }
        if (error is ApiException && error.statusCode == 403) {
          if (attempt == options.maxPartAttempts) rethrow;
          final refreshed = objectList(
            (await _multipartSign(
              session,
              <int>[number],
              ttl,
              cancellation,
            ))['parts'],
          );
          if (refreshed.length != 1 ||
              intValue(refreshed.single['part_number']) != number) {
            throw const ApiException(
              'multipart URL refresh returned no matching part',
            );
          }
          item = refreshed.single;
        } else {
          final retryable =
              error is SignedUploadFailure ||
              error is TransportException ||
              (error is ApiException &&
                  const <int>{
                    408,
                    429,
                    500,
                    502,
                    503,
                    504,
                  }.contains(error.statusCode));
          if (!retryable || attempt == options.maxPartAttempts) rethrow;
        }
        await _cancelableDelay(
          Duration(milliseconds: min(30000, 250 << min(attempt - 1, 6))),
          cancellation,
        );
      }
    }
    throw const ApiException('multipart part attempts exhausted');
  }

  Future<String?> _multipartReconcilePart(
    _MultipartSession session,
    int number,
    int length,
    String localMd5,
    CancellationToken cancellation,
  ) async {
    final status = await _multipartStatus(session, cancellation);
    for (final row in objectList(status['parts'])) {
      if (intValue(row['part_number']) == number &&
          intValue(row['size_bytes']) == length &&
          '${row['etag'] ?? ''}'.toLowerCase() == localMd5.toLowerCase()) {
        return '${row['etag']}';
      }
    }
    return null;
  }

  List<Map<String, Object?>> _multipartFinalParts(
    _MultipartSession session,
    int size,
    Map<String, Object?> status,
  ) {
    final remote = objectList(status['parts'])
      ..sort(
        (Map<String, Object?> a, Map<String, Object?> b) =>
            intValue(a['part_number']).compareTo(intValue(b['part_number'])),
      );
    final numbers = remote
        .map((Map<String, Object?> row) => intValue(row['part_number']))
        .toList();
    if (numbers.length != session.partCount ||
        !List<int>.generate(
          session.partCount,
          (int index) => index + 1,
        ).asMap().entries.every(
          (MapEntry<int, int> entry) => numbers[entry.key] == entry.value,
        )) {
      throw const ApiException(
        'multipart status is missing, duplicate, or unsorted parts',
      );
    }
    return remote.map((Map<String, Object?> row) {
      final number = intValue(row['part_number']);
      final expectedSize = _partLength(size, session.partSize, number);
      final etag = '${row['etag'] ?? ''}';
      final expectedMd5 = session.partMd5[number] ?? '';
      if (intValue(row['size_bytes']) != expectedSize ||
          etag.isEmpty ||
          expectedMd5.isEmpty ||
          etag.toLowerCase() != expectedMd5.toLowerCase()) {
        throw ApiException(
          'multipart status returned an invalid part',
          body: <String, Object?>{'part_number': number},
        );
      }
      return <String, Object?>{'part_number': number, 'etag': etag};
    }).toList();
  }

  Future<Map<String, Object?>> _multipartStatus(
    _MultipartSession session,
    CancellationToken cancellation,
  ) => http.request(
    'GET',
    Routes.full(Routes.externalUploadMultipartStatus),
    params: <String, Object?>{
      'request_id': session.requestId,
      'upload_id': session.uploadId,
      'key': session.key,
    },
    cancellation: cancellation,
  );

  Future<Map<String, Object?>> _multipartSign(
    _MultipartSession session,
    List<int> numbers,
    int ttl,
    CancellationToken cancellation,
  ) => http.request(
    'POST',
    Routes.full(Routes.externalUploadMultipartSignParts),
    json: <String, Object?>{
      'request_id': session.requestId,
      'upload_id': session.uploadId,
      'key': session.key,
      'part_numbers': numbers,
      'ttl': ttl,
    },
    cancellation: cancellation,
  );

  Future<Map<String, Object?>> _multipartAbort(
    _MultipartSession session,
    CancellationToken cancellation,
  ) => http.request(
    'POST',
    Routes.full(Routes.externalUploadMultipartAbort),
    json: <String, Object?>{
      'request_id': session.requestId,
      'upload_id': session.uploadId,
      'key': session.key,
    },
    cancellation: cancellation,
  );

  Future<Map<String, Object?>> _uploadDone(
    String key,
    UploadSource source,
    String collection,
    String stream,
    String mode,
    String modality,
    CancellationToken cancellation,
  ) => http.request(
    'POST',
    Routes.full(Routes.externalUploadDone),
    params: <String, Object?>{
      'key': key,
      'mode': mode,
      'group_name': collection,
      'stream_name': stream,
      'modality': modality,
      'filename': source.fileName,
    },
    cancellation: cancellation,
  );
}

class _UploadContract {
  const _UploadContract({
    required this.source,
    required this.baseUrl,
    required this.userId,
    required this.collection,
    required this.stream,
    required this.mode,
    required this.modality,
    required this.partSize,
  });

  final UploadSource source;
  final String baseUrl;
  final String userId;
  final String collection;
  final String stream;
  final String mode;
  final String modality;
  final int partSize;

  Map<String, Object?> get fields => <String, Object?>{
    'protocol': 'vmodal_multipart_v2',
    'base_url': baseUrl,
    'user_id': userId,
    'source_id': source.sourceId,
    'source_version': source.versionTag,
    'filename': source.fileName,
    'content_type': source.contentType,
    'size_bytes': source.contentLength,
    'part_size_bytes': partSize,
    'mode': mode,
    'group_name': collection,
    'stream_name': stream,
    'modality': modality,
  };

  String get key => sha256.convert(utf8.encode(jsonEncode(fields))).toString();
}

class _MultipartSession {
  _MultipartSession({
    required this.requestId,
    required this.uploadId,
    required this.key,
    required this.partCount,
    required this.partSize,
    Map<int, String>? partMd5,
  }) : partMd5 = partMd5 ?? <int, String>{};

  final String requestId;
  final String uploadId;
  final String key;
  final int partCount;
  final int partSize;
  final Map<int, String> partMd5;

  Map<String, Object?> toJson(_UploadContract contract) => <String, Object?>{
    'version': 2,
    'contract': contract.fields,
    'request_id': requestId,
    'upload_id': uploadId,
    'key': key,
    'part_count': partCount,
    'part_size_bytes': partSize,
    'part_md5': partMd5.map((int key, String value) => MapEntry('$key', value)),
  };

  factory _MultipartSession.fromJson(
    Map<String, Object?> raw,
    _UploadContract contract,
  ) {
    if (intValue(raw['version']) != 2 ||
        jsonEncode(objectMap(raw['contract'])) != jsonEncode(contract.fields)) {
      throw const ApiException('multipart upload checkpoint is incompatible');
    }
    final session = _MultipartSession(
      requestId: '${raw['request_id'] ?? ''}',
      uploadId: '${raw['upload_id'] ?? ''}',
      key: '${raw['key'] ?? ''}',
      partCount: intValue(raw['part_count']),
      partSize: intValue(raw['part_size_bytes']),
      partMd5: objectMap(
        raw['part_md5'],
      ).map((String key, Object? value) => MapEntry(int.parse(key), '$value')),
    );
    if (session.requestId.isEmpty ||
        session.uploadId.isEmpty ||
        session.key.isEmpty ||
        session.partCount <= 0 ||
        session.partSize != contract.partSize) {
      throw const ApiException('multipart upload checkpoint is invalid');
    }
    return session;
  }
}

class _UploadedPart {
  const _UploadedPart(
    this.number,
    this.etag,
    this.size,
    this.md5,
    this.attempts,
  );

  final int number;
  final String etag;
  final int size;
  final String md5;
  final int attempts;
}

Map<String, Object?> _uploadParams(
  UploadSource source,
  String collection,
  String stream,
  String mode,
  String modality,
  int ttl,
) => <String, Object?>{
  'mode': mode,
  'group_name': collection,
  'stream_name': stream,
  'modality': modality,
  'filename': source.fileName,
  'ttl': ttl,
};

VideoUploadResponse _multipartResponse(
  UploadSource source,
  _MultipartSession session,
  String etag,
  bool resumed,
  int attempts,
  Map<String, Object?> done,
) => VideoUploadResponse(<String, Object?>{
  'filename': source.fileName,
  'size_bytes': source.contentLength,
  'status_code': 200,
  'uploaded': true,
  'upload_strategy': 'multipart',
  'upload_id': session.uploadId,
  'key': session.key,
  'etag': etag,
  'part_size_bytes': session.partSize,
  'part_count': session.partCount,
  'parts_uploaded': session.partCount,
  'resumed': resumed,
  'attempt_count': attempts,
  'upload_done': done,
  'dest_path': '${done['dest_path'] ?? ''}',
});

Uri _signedUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw const ValidationException('signed upload URL is empty or invalid');
  }
  return uri;
}

int _partLength(int size, int partSize, int number) =>
    min(partSize, size - (number - 1) * partSize);

int _partCount(int size, int partSize) =>
    size <= 0 ? 1 : 1 + (size - 1) ~/ partSize;

Future<void> _cancelableDelay(
  Duration duration,
  CancellationToken cancellation,
) async {
  await Future.any(<Future<void>>[
    Future<void>.delayed(duration),
    cancellation.whenCanceled,
  ]);
  cancellation.throwIfCanceled();
}
