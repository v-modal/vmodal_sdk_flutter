import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

const userProject = 'framebase_streets';
const userStream = 'street_study';
final _validId = RegExp(r'^[A-Za-z0-9_]+$');

String userCollection(String id) {
  if (id.isEmpty || !_validId.hasMatch(id) || id.contains('__')) {
    throw const ValidationException('Invalid collection user ID');
  }
  final name = 'user_$id';
  if ('${userProject}__$name'.length > 80) {
    throw const ValidationException('Collection user ID is too long');
  }
  return name;
}

String encodedUserCollection(String id) =>
    '${userProject}__${userCollection(id)}';
