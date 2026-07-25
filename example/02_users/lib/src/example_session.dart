import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

const int _foodUserCollectionMax = 70;
final RegExp _userIdPattern = RegExp(r'^[A-Za-z0-9_]+$');

/// Shared progressive setup for the compile-checked organization examples.
final class ExampleSession {
  ExampleSession({
    required String projectId,
    required ApiKeyProvider apiKeyProvider,
  }) : client = VmodalClient(
         config: SdkConfig(apiKeyProvider: apiKeyProvider),
       ) {
    project = VModal.fromClient(projectId: projectId, client: client);
  }

  final VmodalClient client;
  late final VModalProject project;

  Future<UserProfile> authenticate() => client.auth.me();

  Future<List<String>> listCollections() =>
      project.listCollections(mode: 'vid_file');

  Future<void> close() => project.close();
}

String exampleUserCollectionName(String endUserId) {
  final id = endUserId.trim();
  if (id.isEmpty) {
    throw const ValidationException('endUserId is required');
  }
  if (!_userIdPattern.hasMatch(id)) {
    throw const ValidationException(
      'endUserId must contain only letters, digits, and underscore',
    );
  }
  final name = 'user_$id';
  if (name.contains('__')) {
    throw const ValidationException(
      'endUserId must not create the reserved separator "__"',
    );
  }
  if (name.length > _foodUserCollectionMax) {
    throw const ValidationException(
      'endUserId is too long for the food_app project',
    );
  }
  return name;
}
