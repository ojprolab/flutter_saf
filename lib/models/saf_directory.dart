class SAFDirectory {
  final String uri;
  final String? name;
  final String? path;
  final String? bookmarkKey;
  final String? storageType;

  const SAFDirectory({
    required this.uri,
    this.name,
    this.path,
    this.bookmarkKey,
    this.storageType,
  });

  factory SAFDirectory.fromMap(Map<String, dynamic> map) => SAFDirectory(
        uri: map['uri'] as String? ?? '',
        name: map['name'] as String?,
        path: map['path'] as String?,
        bookmarkKey: map['bookmarkKey'] as String?,
        storageType: map['storageType'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'uri': uri,
        'name': name,
        'path': path,
        'bookmarkKey': bookmarkKey,
        'storageType': storageType,
      };

  @override
  String toString() => 'SAFDirectory(name: $name, uri: $uri)';
}
