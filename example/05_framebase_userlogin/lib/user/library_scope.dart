final _validLibraryScope = RegExp(r'^[A-Za-z0-9_]+$');

String validateLibraryScope(Object? scope) {
  if (scope is! String ||
      scope.isEmpty ||
      scope.length > 80 ||
      !_validLibraryScope.hasMatch(scope)) {
    throw const InvalidLibraryScope();
  }
  return scope;
}

class InvalidLibraryScope implements Exception {
  const InvalidLibraryScope();
}
