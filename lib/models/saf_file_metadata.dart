class SAFFileMetadata {
  final String uri;
  final String? name;
  final String? path;
  final int size;
  final String? mimeType;
  final int lastModified;
  final bool isWritable;
  final bool isDirectory;

  const SAFFileMetadata({
    required this.uri,
    required this.size,
    required this.lastModified,
    required this.isWritable,
    required this.isDirectory,
    this.name,
    this.path,
    this.mimeType,
  });

  factory SAFFileMetadata.fromMap(Map<String, dynamic> map) => SAFFileMetadata(
        uri: map['uri'] as String? ?? '',
        name: map['name'] as String?,
        path: map['path'] as String?,
        size: (map['size'] as num?)?.toInt() ?? 0,
        mimeType: map['mimeType'] as String?,
        lastModified: (map['lastModified'] as num?)?.toInt() ?? 0,
        isWritable: map['isWritable'] as bool? ?? false,
        isDirectory: map['isDirectory'] as bool? ?? false,
      );

  Map<String, dynamic> toMap() => {
        'uri': uri,
        'name': name,
        'path': path,
        'size': size,
        'mimeType': mimeType,
        'lastModified': lastModified,
        'isWritable': isWritable,
        'isDirectory': isDirectory,
      };

  DateTime get lastModifiedDate =>
      DateTime.fromMillisecondsSinceEpoch(lastModified, isUtc: true);

  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024)
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  String toString() =>
      'SAFFileMetadata(name: $name, size: $formattedSize, isDirectory: $isDirectory)';
}
