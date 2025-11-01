class SAFException implements Exception {
  final String code;
  final String message;
  final dynamic details;

  SAFException({
    required this.code,
    required this.message,
    this.details,
  });

  @override
  String toString() => 'SAFException($code): $message';
}
