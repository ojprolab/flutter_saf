class SAFDirectory {
  final String uri;
  final String name;
  final String path;
  final String? bookmarkKey;
  final String? storageType;

  SAFDirectory({
    required this.uri,
    required this.name,
    required this.path,
    this.bookmarkKey,
    this.storageType,
  });

  factory SAFDirectory.fromMap(Map<String, dynamic> map) {
    return SAFDirectory(
      uri: map['uri'] as String,
      name: map['name'] as String,
      path: map['path'] as String,
      bookmarkKey: map['bookmarkKey'] as String?,
      storageType: map['storageType'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uri': uri,
      'name': name,
      'path': path,
      'bookmarkKey': bookmarkKey,
      'storageType': storageType,
    };
  }
}
