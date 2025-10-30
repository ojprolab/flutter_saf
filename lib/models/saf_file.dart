class SAFFile {
  final String name;
  final String path;
  final int size;
  final String mimeType;
  final DateTime lastModifiedAt;

  SAFFile({
    required this.name,
    required this.path,
    required this.size,
    required this.mimeType,
    required this.lastModifiedAt,
  });

  factory SAFFile.fromMap(Map<String, dynamic> map) {
    return SAFFile(
      name: map['name'] as String,
      path: map['path'] as String,
      size: map['size'] as int,
      mimeType: map['mimeType'] as String,
      lastModifiedAt: DateTime.fromMillisecondsSinceEpoch(map['lastModified']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'path': path,
      'size': size,
      'mimeType': size,
      'lastModifiedAt': lastModifiedAt,
    };
  }
}
