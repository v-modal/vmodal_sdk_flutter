/// Base class for failures intentionally surfaced by the SDK.
class SdkException implements Exception {
  /// Creates an immutable typed failure.
  const SdkException(
    this.message, {
    this.statusCode = 0,
    this.body,
    this.details,
  });

  /// Human-readable summary safe to show in diagnostic UI.
  final String message;

  /// Service status when available, otherwise zero.
  final int statusCode;

  /// Optional structured or textual response body.
  final Object? body;

  /// Optional local diagnostic details or cause.
  final Object? details;

  @override
  String toString() {
    final status = statusCode == 0 ? '' : ' | status=$statusCode';
    return '$runtimeType: $message$status';
  }
}

/// Credential or identity-resolution failure.
class AuthException extends SdkException {
  const AuthException(
    super.message, {
    super.statusCode = 401,
    super.body,
    super.details,
  });
}

/// Valid service response that represents an unsuccessful operation.
class ApiException extends SdkException {
  const ApiException(
    super.message, {
    super.statusCode,
    super.body,
    super.details,
  });
}

/// Invalid caller input detected before or while preparing an operation.
class ValidationException extends SdkException {
  const ValidationException(
    super.message, {
    super.statusCode = 422,
    super.body,
    super.details,
  });
}

/// Compatibility method that is intentionally unavailable.
class FeatureDisabled extends SdkException {
  const FeatureDisabled(super.message);
}

/// Connectivity, timeout, stream, or lower-level transport failure.
class TransportException extends SdkException {
  const TransportException([Object? cause])
    : super('transport error', details: cause);
}

/// Response or checkpoint exceeded an SDK safety limit.
class ResponseTooLarge extends SdkException {
  const ResponseTooLarge(this.limitBytes, this.observedBytes)
    : super('response exceeds the configured limit');

  final int limitBytes;
  final int observedBytes;
}

/// Structured response could not be decoded into the documented contract.
class MalformedResponse extends SdkException {
  const MalformedResponse([super.message = 'malformed JSON response']);
}

/// Operation stopped because its [CancellationToken] was canceled.
class OperationCanceled extends SdkException {
  const OperationCanceled() : super('operation canceled');
}
