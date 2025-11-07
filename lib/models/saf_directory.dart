class SAFDirectory {
  final String uri;
  final String name;
  final String path;
  final String? bookmarkKey;

  SAFDirectory({
    required this.uri,
    required this.name,
    required this.path,
    this.bookmarkKey,
  });

  factory SAFDirectory.fromMap(Map<String, dynamic> map) {
    return SAFDirectory(
      uri: map['uri'] as String,
      name: map['name'] as String,
      path: map['path'] as String,
      bookmarkKey: map['bookmarkKey'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uri': uri,
      'name': name,
      'path': path,
      'bookmarkKey': bookmarkKey,
    };
  }
}
