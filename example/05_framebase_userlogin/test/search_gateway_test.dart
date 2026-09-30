import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:framebase/data/search_gateway.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

const accountScope = 'scope_7K3A';
SearchGateway testGateway(QueueTransport transport) => SearchGateway(
  MutableApiKeyProvider('test-only-placeholder'),
  accountScope,
  transport: transport,
);

String requestText(VmodalRequest request) =>
    '${request.uri} ${request.jsonBody ?? ''}';

class QueueTransport implements VmodalTransport {
  QueueTransport(this.responses);
  final List<Map<String, Object?>> responses;
  final List<VmodalRequest> requests = [];
  bool closed = false;
  @override
  Future<VmodalResponse> send(VmodalRequest request) async {
    request.cancellation.throwIfCanceled();
    requests.add(request);
    final data = responses.removeAt(0);
    return VmodalResponse(
      statusCode: data['__status'] as int? ?? 200,
      body: Stream.value(utf8.encode(jsonEncode(data))),
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  test(
    'connect resolves the account and discovers the current index',
    () async {
      final transport = QueueTransport([
        {'user_id': 'account-1'},
        {
          'total': 1,
          'data': [
            {
              'mode': 'vid_file',
              'group_name': accountScope,
              'lancedb_versions': ['v2', 'v4'],
            },
          ],
        },
        {'data': [], 'total': 0},
      ]);
      final gateway = testGateway(transport);

      await gateway.connect('account-1');

      expect(gateway.accountId, 'account-1');
      expect(gateway.collection, accountScope);
      expect(gateway.version, 4);
      expect(transport.requests, hasLength(3));
      expect(
        transport.requests.last.uri.queryParameters['group_name'],
        accountScope,
      );
      expect(
        transport.requests.map(requestText).join(' '),
        isNot(contains('framebase_streets__user_')),
      );
      await gateway.close();
    },
  );

  test(
    'bulk frames retain search order and tolerate partial missing images',
    () async {
      const route = '/api/external/v1/image/get_image';
      final transport = QueueTransport([
        {
          'data': [
            {'title': 'first', 'ts_unix': '0000000006000', 'score': .71},
            {'title': 'second', 'ts_unix': '0000000008000', 'score': .76},
            {'title': 'missing', 'ts_unix': '0000000010000', 'score': .80},
          ],
          'cnt_total': 3,
          'execution_time_ms': 42.5,
        },
        {
          'records': [
            {
              'input_index': 1.0,
              'found': true,
              'url_pre_signed': '$route?test=second',
            },
            {
              'input_index': '0',
              'found': true,
              'url_pre_signed': '$route?test=first',
            },
            {'input_index': 2, 'found': false},
            {
              'input_index': -1,
              'found': true,
              'url_pre_signed': 'http://invalid.test',
            },
          ],
        },
        {
          'records': [
            {
              'url_pre_signed': '$route?test=first',
              'content_base64': base64Encode([1, 2, 3]),
            },
            {
              'url_pre_signed': '$route?test=second',
              'content_base64': base64Encode([4, 5, 6]),
            },
          ],
        },
      ]);
      final gateway = testGateway(transport);
      gateway.version = 2;
      final result = await gateway.search('crosswalk', maxDistance: .85);
      expect(result.matches.map((m) => m.fileName), [
        'first',
        'second',
        'missing',
      ]);
      expect(result.matches[0].imageBytes, [1, 2, 3]);
      expect(result.matches[1].imageBytes, [4, 5, 6]);
      expect(result.matches[2].imageBytes, isNull);
      expect(result.matches[0].imageUrl, isNull);
      expect(result.matches[0].seconds, 6);
      expect(result.serverMs, 42.5);
      final body = transport.requests.first.jsonBody as Map;
      expect(body['group_name'], accountScope);
      expect(body['stream_name'], archiveStream);
      expect(body['image_emb_score_min'], .85);
      expect(transport.requests[1].jsonBody.toString(), contains(accountScope));
      expect(
        transport.requests[1].jsonBody.toString(),
        contains(archiveStream),
      );
      await gateway.close();
      expect(transport.closed, isTrue);
      expect(() => gateway.keys.current(), throwsA(isA<AuthException>()));
    },
  );

  test(
    'typed previews skip resolution and canonical offsets drive selectors',
    () async {
      const route = '/api/external/v1/image/get_image';
      const direct = 'https://images.test/direct.jpg';
      final transport = QueueTransport([
        {
          'data': [
            {
              'asset_id': 'asset-direct',
              'file_name': 'direct.mp4',
              'playback_offset_ms': 12000,
              'distance': .4,
              'preview_image_url': direct,
            },
            {
              'asset_id': 'asset-offset',
              'file_name': 'offset.mp4',
              'playback_offset_ms': 35000,
              'distance': .5,
            },
            {
              'asset_id': 'asset-epoch',
              'file_name': 'epoch.mp4',
              'ts_unix': '1788510000000',
              'distance': .6,
            },
          ],
          'cnt_total': 3,
        },
        {
          'records': [
            {
              'input_index': 0,
              'found': true,
              'url_pre_signed': '$route?test=offset',
            },
            {'input_index': 1, 'found': false},
          ],
        },
        {
          'records': [
            {
              'url_pre_signed': direct,
              'content_base64': base64Encode([1]),
            },
            {
              'url_pre_signed': '$route?test=offset',
              'content_base64': base64Encode([2]),
            },
          ],
        },
      ]);
      final gateway = testGateway(transport);
      final result = await gateway.search('street', maxDistance: .85);

      expect(result.matches.map((match) => match.assetId), [
        'asset-direct',
        'asset-offset',
        'asset-epoch',
      ]);
      expect(result.matches[0].imageUrl, direct);
      expect(result.matches[0].imageBytes, [1]);
      expect(result.matches[1].seconds, 35);
      expect(result.matches[1].imageBytes, [2]);
      expect(result.matches[2].seconds, isNull);
      expect(transport.requests, hasLength(3));
      final lookup = transport.requests[1].jsonBody as Map;
      final records = lookup['records'] as List;
      expect(records, hasLength(2));
      expect(records.toString(), isNot(contains('direct.mp4')));
      expect((records[0] as Map)['ts_unix_13digits'], '0000000035000');
      expect(records[1] as Map, isNot(contains('ts_unix_13digits')));
      await gateway.close();
    },
  );

  test('empty search does not request invented images', () async {
    final transport = QueueTransport([
      {'data': [], 'cnt_total': 0},
    ]);
    final gateway = testGateway(transport);
    final result = await gateway.search('a dog on a beach');
    expect(result.matches, isEmpty);
    expect(transport.requests, hasLength(1));
    await gateway.close();
  });

  test(
    'client cutoff rejects out-of-threshold beta results before downloading',
    () async {
      final transport = QueueTransport([
        {
          'data': [
            {'title': 'street', 'score': .926, 'ts_unix': '0000000006000'},
          ],
          'cnt_total': 1,
        },
      ]);
      final gateway = testGateway(transport);
      final result = await gateway.search('a dog on a beach', maxDistance: .85);
      expect(result.matches, isEmpty);
      expect(result.total, 1); // Raw server count is not rewritten.
      expect(transport.requests, hasLength(1));
      await gateway.close();
    },
  );

  test('canceled search never reaches transport', () async {
    final transport = QueueTransport([]);
    final gateway = testGateway(transport);
    final token = CancellationToken()..cancel();
    await expectLater(
      gateway.search('bus', cancellation: token),
      throwsA(isA<OperationCanceled>()),
    );
    expect(transport.requests, isEmpty);
    await gateway.close();
  });

  test(
    'index creation uses the user scope and status uses returned ID',
    () async {
      final transport = QueueTransport([
        {'job_id': 'job-123', 'status': 'queued'},
        {'job_id': 'job-123', 'status': 'success'},
      ]);
      final gateway = testGateway(transport);
      final token = CancellationToken();
      final job = await gateway.createIndex(token);
      final status = await gateway.indexStatus(job.jobId, token);
      expect(job.jobId, 'job-123');
      expect(status.status, 'success');
      final body = transport.requests.first.jsonBody as Map;
      expect(body['group_name'], accountScope);
      expect(body['stream_name'], archiveStream);
      expect(transport.requests.last.uri.path, contains('job-123'));
      await gateway.close();
    },
  );

  test('upload signed request uses the exact immutable scope', () async {
    final root = await Directory.systemTemp.createTemp('scope_upload_');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/clip.mp4');
    await file.writeAsBytes([1, 2, 3]);
    final transport = QueueTransport([
      {'url': ''},
    ]);
    final gateway = testGateway(transport);
    final task = await gateway.upload(file);
    await expectLater(task.result, throwsA(isA<ValidationException>()));
    expect(transport.requests, hasLength(1));
    expect(
      transport.requests.single.uri.queryParameters['group_name'],
      accountScope,
    );
    expect(
      requestText(transport.requests.single),
      isNot(contains('framebase_streets__user_')),
    );
    expect(gateway.collection, accountScope);
    await gateway.close();
  });

  test('401 reports auth failure without replaying the search', () async {
    final transport = QueueTransport([
      {'__status': 401, 'detail': 'expired'},
    ]);
    final gateway = testGateway(transport);
    var status = 0;
    gateway.onAccessFailure = (value) => status = value;
    await expectLater(gateway.search('bus'), throwsA(isA<AuthException>()));
    expect(status, 401);
    expect(transport.requests, hasLength(1));
    await gateway.close();
  });

  test('403 reports forbidden failure without replaying the search', () async {
    final transport = QueueTransport([
      {'__status': 403, 'detail': 'forbidden'},
    ]);
    final gateway = testGateway(transport);
    var status = 0;
    gateway.onAccessFailure = (value) => status = value;
    await expectLater(gateway.search('bus'), throwsA(isA<ApiException>()));
    expect(status, 403);
    expect(transport.requests, hasLength(1));
    await gateway.close();
  });

  test(
    'cloud deletion preview and commit use the exact issued scope',
    () async {
      final transport = QueueTransport([
        {
          'status': 'dry_run',
          'group_name': accountScope,
          'mode': 'vid_file',
          'scope': 'all',
        },
        {
          'status': 'ok',
          'group_name': accountScope,
          'mode': 'vid_file',
          'scope': 'all',
        },
      ]);
      final gateway = testGateway(transport);

      await gateway.previewLibraryDeletion(CancellationToken());
      await gateway.deleteLibrary(CancellationToken());

      expect(transport.requests, hasLength(2));
      expect(
        transport.requests.map((request) => request.method),
        everyElement('DELETE'),
      );
      expect(
        transport.requests.map((request) => request.uri.path),
        everyElement(endsWith('/api/external/v1/collection/delete')),
      );
      expect(transport.requests.first.jsonBody, {
        'group_name': accountScope,
        'mode': 'vid_file',
        'scope': 'all',
        'dry_run': true,
        'confirm': false,
      });
      expect(transport.requests.last.jsonBody, {
        'group_name': accountScope,
        'mode': 'vid_file',
        'scope': 'all',
        'dry_run': false,
        'confirm': true,
      });
      expect(requestText(transport.requests.last), isNot(contains('asset_id')));
      expect(
        requestText(transport.requests.last),
        isNot(contains('stream_name')),
      );
      await gateway.close();
    },
  );

  test(
    'cloud deletion is not replayed and honors pre-send cancellation',
    () async {
      final canceledTransport = QueueTransport([]);
      final canceledGateway = testGateway(canceledTransport);
      final canceled = CancellationToken()..cancel();
      await expectLater(
        canceledGateway.deleteLibrary(canceled),
        throwsA(isA<OperationCanceled>()),
      );
      expect(canceledTransport.requests, isEmpty);
      await canceledGateway.close();

      for (final status in [409, 500]) {
        final transport = QueueTransport([
          {'__status': status, 'detail': 'failure'},
        ]);
        final gateway = testGateway(transport);
        await expectLater(
          gateway.deleteLibrary(CancellationToken()),
          throwsA(isA<SdkException>()),
        );
        expect(transport.requests, hasLength(1));
        await gateway.close();
      }
    },
  );
}
