import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:framebase/data/search_gateway.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';
import 'session_fixture.dart';

const accountScope = 'scope_7K3A';
Future<SearchGateway> testGateway(
  QueueTransport transport, {
  bool collectionWide = true,
}) async => SearchGateway(
  await testSession(transport: transport, collectionWide: collectionWide),
  accountScope,
);

class DelayedTransport extends QueueTransport {
  final response = Completer<VmodalResponse>();
  @override
  Future<VmodalResponse> send(VmodalRequest request) {
    requests.add(request);
    return response.future;
  }
}

class ByteTransport extends QueueTransport {
  ByteTransport(super.responses);
  @override
  Future<VmodalResponse> send(VmodalRequest request) {
    if (request.uri.path.endsWith('/image/get_image')) {
      requests.add(request);
      return Future.value(
        VmodalResponse(statusCode: 200, body: Stream.value([1, 2, 3])),
      );
    }
    return super.send(request);
  }
}

void main() {
  test(
    'explicit collection-wide grant previews then commits exact opaque collection',
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
      final gateway = await testGateway(transport);
      await gateway.previewLibraryDeletion(CancellationToken());
      await gateway.deleteLibrary(CancellationToken());
      expect(transport.requests.map((r) => r.method), ['DELETE', 'DELETE']);
      expect(transport.requests.first.jsonBody, {
        'group_name': accountScope,
        'mode': 'vid_file',
        'scope': 'all',
        'dry_run': true,
        'confirm': false,
      });
      expect((transport.requests.last.jsonBody as Map)['confirm'], isTrue);
      await gateway.close();
    },
  );

  test('forbidden deletion reports host denial once without replay', () async {
    final transport = QueueTransport([
      {'__status': 403, 'detail': 'private-body'},
    ]);
    final gateway = await testGateway(transport);
    final failures = <int>[];
    gateway.onAccessFailure = failures.add;
    await expectLater(
      gateway.deleteLibrary(CancellationToken()),
      throwsA(isA<ApiException>()),
    );
    expect(failures, [403]);
    expect(transport.requests, hasLength(1));
    await gateway.close();
  });

  test(
    'upload preparation keeps exact scoped selectors and does not expose signed credentials',
    () async {
      final root = await Directory.systemTemp.createTemp('scoped_upload_');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/clip.mp4');
      await file.writeAsBytes([1, 2, 3]);
      final transport = QueueTransport([
        {'url': ''},
      ]);
      final gateway = await testGateway(transport);
      final task = await gateway.upload(file);
      await expectLater(task.result, throwsA(isA<SdkException>()));
      expect(transport.requests, hasLength(1));
      expect(
        transport.requests.single.uri.queryParameters['group_name'],
        accountScope,
      );
      expect(
        transport.requests.single.uri.queryParameters['stream_name'],
        archiveStream,
      );
      await gateway.close();
    },
  );
  test(
    'safe media bytes preserve frame order offsets and placeholders without exposing URLs',
    () async {
      const signed = 'https://images.test/private-capability';
      final transport = ByteTransport([
        {
          'data': [
            {
              'asset_id': 'asset-first',
              'file_name': 'first.mp4',
              'distance': .4,
              'playback_offset_ms': 35000,
              'preview_image_url': signed,
            },
            {
              'asset_id': 'asset-missing',
              'file_name': 'missing.mp4',
              'distance': .5,
              'ts_unix': '1788510000000',
            },
          ],
        },
        {'found': true, 'url_pre_signed': signed},
        {'found': false},
      ]);
      final gateway = await testGateway(transport);
      final batch = await gateway.search('street');
      expect(batch.matches.map((m) => m.assetId), [
        'asset-first',
        'asset-missing',
      ]);
      expect(batch.matches.first.imageBytes, [1, 2, 3]);
      expect(batch.matches.first.seconds, 35);
      expect(batch.matches.last.seconds, isNull);
      expect(batch.matches.last.imageBytes, isNull);
      expect(batch.matches.every((m) => m.imageUrl == null), isTrue);
      expect(batch.matches.first.hit.raw.toString(), isNot(contains(signed)));
      expect(transport.requests, hasLength(3));
      expect(
        (transport.requests[1].jsonBody as Map)['ts_unix_13digits'],
        '0000000035000',
      );
      expect(
        transport.requests[1].jsonBody.toString(),
        isNot(contains('1788510000000')),
      );
      await gateway.close();
    },
  );
  test(
    'tenant principal verification preserves app-user identity and opaque scope',
    () async {
      final transport = QueueTransport([
        {'user_id': 'shared-principal'},
        {
          'data': [
            {
              'mode': 'vid_file',
              'group_name': accountScope,
              'lancedb_versions': ['v2', 'v4'],
            },
          ],
        },
        {'data': []},
      ]);
      final gateway = await testGateway(transport);
      await gateway.connect('shared-principal');
      expect(gateway.accountId, 'alice');
      expect(gateway.context.tenantId, 'shared-tenant');
      expect(gateway.version, 4);
      expect(
        transport.requests.last.uri.queryParameters['group_name'],
        accountScope,
      );
      expect(
        transport.requests.every((r) => !r.headers.containsKey('X-User-Id')),
        isTrue,
      );
      await gateway.close();
    },
  );

  test(
    'safe search rows omit tenant data and signed image capabilities',
    () async {
      final transport = QueueTransport([
        {
          'data': [
            {'file_name': 'first.mp4', 'distance': .4},
            {
              'file_name': 'foreign.mp4',
              'group_name': 'scope_bob',
              'distance': .4,
            },
            {'file_name': 'far.mp4', 'distance': 1.2},
          ],
          'cnt_total': 900,
          'execution_time_ms': 42.5,
        },
        {'records': []},
      ]);
      final gateway = await testGateway(transport);
      final batch = await gateway.search('crosswalk', maxDistance: .85);
      expect(batch.matches.map((m) => m.fileName), ['first.mp4']);
      expect(batch.total, 1);
      expect(batch.matches.single.imageUrl, isNull);
      // Restricted responses omit timing/count fields for broader tenant work.
      expect(batch.serverMs, 0);
      final body = transport.requests.first.jsonBody as Map;
      expect(body['group_name'], accountScope);
      expect(body['stream_name'], archiveStream);
      await gateway.close();
    },
  );

  test('empty and canceled searches do not invent media or dispatch', () async {
    final transport = QueueTransport([
      {'data': []},
    ]);
    final gateway = await testGateway(transport);
    expect((await gateway.search('bus')).matches, isEmpty);
    await expectLater(
      gateway.search('bus', cancellation: CancellationToken()..cancel()),
      throwsA(isA<OperationCanceled>()),
    );
    expect(transport.requests, hasLength(1));
    await gateway.close();
    await expectLater(gateway.search('bus'), throwsA(isA<OperationCanceled>()));
  });

  test(
    'index status accepts minted provenance and rejects another session job',
    () async {
      final aTransport = QueueTransport([
        {'job_id': 'job-a', 'status': 'queued'},
        {'job_id': 'job-a', 'status': 'success'},
      ]);
      final a = await testGateway(aTransport);
      final bTransport = QueueTransport();
      final b = await testGateway(bTransport);
      final job = await a.createIndex(CancellationToken());
      expect((await a.indexStatus(job, CancellationToken())).status, 'success');
      await expectLater(
        b.indexStatus(job, CancellationToken()),
        throwsA(isA<ValidationException>()),
      );
      expect(bTransport.requests, isEmpty);
      await a.close();
      await b.close();
    },
  );

  test('one-stream grant cannot delete the whole collection', () async {
    final transport = QueueTransport();
    final gateway = await testGateway(transport, collectionWide: false);
    await expectLater(
      gateway.deleteLibrary(CancellationToken()),
      throwsA(isA<ValidationException>()),
    );
    expect(transport.requests, isEmpty);
    await gateway.close();
  });

  test(
    'account switch closes retained gateway and drops ignored-cancel payload',
    () async {
      final transport = DelayedTransport();
      final gateway = await testGateway(transport);
      final pending = expectLater(
        gateway.search('bus'),
        throwsA(isA<OperationCanceled>()),
      );
      await Future<void>.delayed(Duration.zero);
      await gateway.close();
      await pending;
      transport.response.complete(
        VmodalResponse(
          statusCode: 200,
          body: Stream.value(
            utf8.encode(
              jsonEncode({
                'data': [
                  {'file_name': 'private-a'},
                ],
              }),
            ),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(transport.closed, isTrue);
    },
  );

  test('stale errors cannot notify the active host', () async {
    final gateway = await testGateway(QueueTransport());
    var reports = 0;
    gateway.onAccessFailure = (_) => reports++;
    await gateway.close();
    gateway.reportFailure(const AuthException('expired'));
    gateway.reportFailure(const ApiException('forbidden', statusCode: 403));
    expect(reports, 0);
  });
}
