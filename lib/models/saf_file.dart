class SAFFile {
  final String uri;
  final String name;
  final String path;
  final int size;
  final String mimeType;
  final DateTime lastModifiedAt;

  SAFFile({
    required this.uri,
    required this.name,
    required this.path,
    required this.size,
    required this.mimeType,
    required this.lastModifiedAt,
  });

  factory SAFFile.fromMap(Map<String, dynamic> map) {
    return SAFFile(
      uri: map['uri'] as String,
      name: map['name'] as String,
      path: map['path'] as String,
      size: map['size'] as int,
      mimeType: map['mimeType'] as String,
      lastModifiedAt: DateTime.fromMillisecondsSinceEpoch(map['lastModified']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uri': uri,
      'name': name,
      'path': path,
      'size': size,
      'mimeType': size,
      'lastModifiedAt': lastModifiedAt,
    };
  }
}
