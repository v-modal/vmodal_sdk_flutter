import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

void main() {
  test('exception strings do not expose decoded endpoint values', () {
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
}
