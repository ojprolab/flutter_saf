class SAFDirectory {
  final String uri;
  final String name;
  final String path;

  SAFDirectory({
    required this.uri,
    required this.name,
    required this.path,
  });

  factory SAFDirectory.fromMap(Map<String, dynamic> map) {
    return SAFDirectory(
      uri: map['uri'] as String,
      name: map['name'] as String,
      path: map['path'] as String,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uri': uri,
      'name': name,
      'path': path,
    };
  }
}
