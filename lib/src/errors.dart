class SdkException implements Exception {
  const SdkException(
    this.message, {
    this.statusCode = 0,
    this.body,
    this.details,
  });

  final String message;
  final int statusCode;
  final Object? body;
  final Object? details;

  @override
  String toString() {
    final status = statusCode == 0 ? '' : ' | status=$statusCode';
    return '$runtimeType: $message$status';
  }
}

class AuthException extends SdkException {
  const AuthException(
    super.message, {
    super.statusCode = 401,
    super.body,
    super.details,
  });
}

class ApiException extends SdkException {
  const ApiException(
    super.message, {
    super.statusCode,
    super.body,
    super.details,
  });
}

class ValidationException extends SdkException {
  const ValidationException(
    super.message, {
    super.statusCode = 422,
    super.body,
    super.details,
  });
}

class FeatureDisabled extends SdkException {
  const FeatureDisabled(super.message);
}

class TransportException extends SdkException {
  const TransportException([Object? cause])
    : super('transport error', details: cause);
}

class ResponseTooLarge extends SdkException {
  const ResponseTooLarge(this.limitBytes, this.observedBytes)
    : super('response exceeds the configured limit');

  final int limitBytes;
  final int observedBytes;
}

class MalformedResponse extends SdkException {
  const MalformedResponse([super.message = 'malformed JSON response']);
}

class OperationCanceled extends SdkException {
  const OperationCanceled() : super('operation canceled');
}
