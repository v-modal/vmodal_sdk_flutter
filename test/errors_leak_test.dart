import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

void main() {
  test('exception strings do not expose decoded endpoint values', () {
    stdout.writeln('[errors] checking safe exception strings');
    final route = Routes.full(Routes.searchClient);
    final errors = <SdkException>[
      const ValidationException('invalid request'),
      ApiException('request failed', body: <String, String>{'path': route}),
      TransportException(Exception(route)),
    ];
    for (final error in errors) {
      final text = error.toString();
      expect(
        text,
        isNot(contains(route)),
        reason: error.runtimeType.toString(),
      );
      expect(
        text,
        isNot(contains(publicGatewayUrl)),
        reason: error.runtimeType.toString(),
      );
      expect(
        text,
        isNot(contains(devGatewayUrl)),
        reason: error.runtimeType.toString(),
      );
    }
  });

  test('server response details redact nested filesystem paths', () async {
    stdout.writeln(
      '[errors] checking application-visible server response details',
    );
    const unixPath = '/srv/private folder/lancedb/user/table';
    const windowsPath = r'C:\private folder\lancedb\user\table';
    const uncPath = r'\\server\private\lancedb\table';
    const fileUri = 'file:///opt/private/lancedb/table';
    final fake = FakeTransport()
      ..addJson(<String, Object?>{
        'detail': 'Missing LanceDB table: $unixPath',
        'debug': <String, Object?>{
          'trace': 'failed at $windowsPath',
          'checkpoint': uncPath,
          'source': fileUri,
        },
      }, status: 422);
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );

    await expectLater(
      client.searches.searchVideo(const SearchRequest(queryText: 'one')),
      throwsA(
        isA<ValidationException>()
            .having(
              (ValidationException error) => '${error.body}',
              'body',
              allOf(
                contains('****'),
                isNot(contains(unixPath)),
                isNot(contains(windowsPath)),
                isNot(contains(uncPath)),
                isNot(contains(fileUri)),
              ),
            )
            .having(
              (ValidationException error) => '${error.details}',
              'details',
              allOf(contains('****'), isNot(contains(unixPath))),
            ),
      ),
    );
    await client.close();

    const textBody = 'backend trace at $unixPath';
    final textFake = FakeTransport()
      ..addResponse(
        VmodalResponse(
          statusCode: 500,
          headers: const <String, String>{'content-type': 'text/plain'},
          contentLength: textBody.length,
          body: Stream<List<int>>.value(textBody.codeUnits),
        ),
      );
    final textClient = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: textFake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    await expectLater(
      textClient.searches.searchVideo(const SearchRequest(queryText: 'one')),
      throwsA(
        isA<ApiException>().having(
          (ApiException error) => error.body,
          'plain-text body',
          allOf(contains('****'), isNot(contains(unixPath))),
        ),
      ),
    );
    await textClient.close();
  });
}
