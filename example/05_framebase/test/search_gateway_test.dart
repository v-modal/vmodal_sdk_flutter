import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:framebase/data/search_gateway.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

class QueueTransport implements VmodalTransport {
  QueueTransport(this.responses);
  final List<Map<String, Object?>> responses;
  final List<VmodalRequest> requests = [];
  bool closed = false;
  @override
  Future<VmodalResponse> send(VmodalRequest request) async {
    request.cancellation.throwIfCanceled();
    requests.add(request);
    return VmodalResponse(
      statusCode: 200,
      body: Stream.value(utf8.encode(jsonEncode(responses.removeAt(0)))),
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
              'group_name': archiveCollection,
              'lancedb_versions': ['v2', 'v4'],
            },
          ],
        },
      ]);
      final gateway = SearchGateway(
        'test-only-placeholder',
        transport: transport,
      );

      await gateway.connect();

      expect(gateway.accountId, 'account-1');
      expect(gateway.version, 4);
      expect(transport.requests, hasLength(2));
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
      final gateway = SearchGateway(
        'test-only-placeholder',
        transport: transport,
      );
      gateway.version = 2;
      final result = await gateway.search('crosswalk', maxDistance: .85);
      expect(result.matches.map((m) => m.filename), [
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
      expect(body['group_name'], archiveCollection);
      expect(body['stream_name'], archiveStream);
      expect(body['image_emb_score_min'], .85);
      await gateway.close();
      expect(transport.closed, isTrue);
      expect(() => gateway.keys.current(), throwsA(isA<AuthException>()));
    },
  );

  test('empty search does not request invented images', () async {
    final transport = QueueTransport([
      {'data': [], 'cnt_total': 0},
    ]);
    final gateway = SearchGateway(
      'test-only-placeholder',
      transport: transport,
    );
    final result = await gateway.search('a dog on a beach');
    expect(result.matches, isEmpty);
    expect(transport.requests, hasLength(1));
    await gateway.close();
  });

  test(
    'reference photo search keeps only recordings from the selected trip',
    () async {
      const route = '/api/external/v1/image/get_image';
      final transport = QueueTransport([
        {
          'data': [
            {
              'filename': 'downtown_traffic.mp4',
              'ts_unix': '0000000008000',
              'score': .62,
            },
            {
              'filename': 'evening_junction.mp4',
              'ts_unix': '0000000010000',
              'score': .58,
            },
          ],
          'cnt_total': 2,
        },
        {
          'records': [
            {
              'input_index': 0,
              'found': true,
              'url_pre_signed': '$route?test=singapore',
            },
          ],
        },
        {
          'records': [
            {
              'url_pre_signed': '$route?test=singapore',
              'content_base64': base64Encode([7, 8, 9]),
            },
          ],
        },
      ]);
      final gateway = SearchGateway(
        'test-only-placeholder',
        transport: transport,
      );
      final result = await gateway.search(
        '',
        imageQuery: 'base64-reference',
        allowedFilenames: {'downtown_traffic.mp4'},
      );
      expect(result.matches, hasLength(1));
      expect(result.matches.single.filename, 'downtown_traffic.mp4');
      expect(result.matches.single.imageBytes, [7, 8, 9]);
      final body = transport.requests.first.jsonBody as Map;
      expect(body['query_text'], '');
      expect(body['image_query'], 'base64-reference');
      await gateway.close();
    },
  );

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
      final gateway = SearchGateway(
        'test-only-placeholder',
        transport: transport,
      );
      final result = await gateway.search('a dog on a beach', maxDistance: .85);
      expect(result.matches, isEmpty);
      expect(result.total, 1); // Raw server count is not rewritten.
      expect(transport.requests, hasLength(1));
      await gateway.close();
    },
  );

  test('canceled search never reaches transport', () async {
    final transport = QueueTransport([]);
    final gateway = SearchGateway(
      'test-only-placeholder',
      transport: transport,
    );
    final token = CancellationToken()..cancel();
    await expectLater(
      gateway.search('bus', cancellation: token),
      throwsA(isA<OperationCanceled>()),
    );
    expect(transport.requests, isEmpty);
    await gateway.close();
  });
}
