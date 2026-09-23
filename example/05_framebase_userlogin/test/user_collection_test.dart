import 'package:flutter_test/flutter_test.dart';
import 'package:framebase/user/user_collection.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

void main() {
  test('stable project and user scope', () {
    expect(userCollection('A_9'), 'user_A_9');
    expect(encodedUserCollection('A_9'), 'framebase_streets__user_A_9');
    expect(encodedUserCollection('A_9'), encodedUserCollection('A_9'));
  });
  test('invalid IDs cannot collide or exceed the backend limit', () {
    for (final id in ['', 'a-b', 'a.b', 'a b', 'a__b', ' a', 'é']) {
      expect(
        () => userCollection(id),
        throwsA(isA<ValidationException>()),
        reason: 'invalid ID: $id',
      );
    }
    const prefix = 'framebase_streets__user_';
    final maxId = 'a' * (80 - prefix.length);
    expect(encodedUserCollection(maxId).length, 80);
    expect(
      () => userCollection('${maxId}a'),
      throwsA(isA<ValidationException>()),
    );
  });
}
