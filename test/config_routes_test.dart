import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

void main() {
  test('route fixture exactly matches categorized SDK routes', () {
    final rows =
        (jsonDecode(
                  File('test/fixtures/routes_contract.json').readAsStringSync(),
                )
                as List)
            .cast<Map<String, Object?>>();
    expect(rows, hasLength(Routes.specs.length));
    expect(
      rows.map((Map<String, Object?> row) => row['name']).toSet(),
      hasLength(rows.length),
    );
    expect(
      Routes.specs
          .where(
            (RouteSpec row) =>
                row.category == RouteCategory.multipartExperimental,
          )
          .length,
      5,
    );
    expect(
      Routes.specs
          .singleWhere(
            (RouteSpec row) =>
                row.name == 'collections.upload_google_drive_folder',
          )
          .category,
      RouteCategory.deprecated,
    );
  });

  test('prefix resolver rejects absolute API URLs', () {
    expect(Routes.full('/health'), '/api/external/v1/health');
    expect(Routes.usersFull('/auth/me'), '/api/v1/auth/me');
    expect(
      () => Routes.full('https://evil.test/path'),
      throwsA(isA<ValidationException>()),
    );
  });

  test('configuration normalizes gateway once and redacts values', () {
    const key = 'sentinel-key-do-not-print';
    const user = 'sentinel-user-do-not-print';
    final config = SdkConfig(
      baseUrl: 'https://gateway.test/',
      userId: user,
      token: key,
    );
    expect(
      config.normalizedBaseUrl,
      'https://gateway.test/api/v1/proxy/search_api',
    );
    expect(config.toString(), isNot(contains(key)));
    expect(config.toString(), isNot(contains(user)));
    expect(strUsersBaseUrl(config.normalizedBaseUrl), 'https://gateway.test');
  });

  test('invalid configuration fails before transport', () {
    expect(
      () => SdkConfig(baseUrl: 'http://remote.test'),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => SdkConfig(maxRetries: -1),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => SdkConfig(timeout: Duration.zero),
      throwsA(isA<ValidationException>()),
    );
  });
}
