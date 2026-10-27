import 'dart:convert';

import 'package:crypto/crypto.dart';

typedef Json = Map<String, dynamic>;

List<String> serverSort(String kind, String value) =>
    value.split('|').map((part) {
      final pieces = part.split(',');
      final field = kind == 'books'
          ? ({
                  'metadata.titleSort': 'metadata.title',
                  'created': 'createdDate',
                  'lastModified': 'lastModifiedDate',
                }[pieces.first] ??
                pieces.first)
          : pieces.first;
      return [field, ...pieces.skip(1)].join(',');
    }).toList();
Object sortQuery(String kind, String value) {
  final fields = serverSort(kind, value);
  return fields.length == 1 ? fields.single : fields;
}

String sortFields(String kind, String value) => serverSort(kind, value)
    .map((part) {
      final end = part.lastIndexOf(',');
      return end < 0 ? part : part.substring(0, end);
    })
    .join('|');

Json object(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
int integer(dynamic value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;
String text(dynamic value, [String fallback = '']) =>
    value is String ? value : fallback;

Uri normalizeServerUrl(String input) {
  var value = input.trim();
  if (!value.contains('://')) value = 'https://$value';
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(
      'Enter an HTTP or HTTPS server address without credentials, query, or fragment.',
    );
  }
  return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
}

enum Authentication { password, apiKey }

class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.url,
    required this.email,
    required this.authentication,
    this.admin = false,
    this.apiKeyId,
    this.managedKey = false,
    this.userId,
  });
  final String id, name, url, email;
  final Authentication authentication;
  final bool admin;
  final String? apiKeyId;
  final bool managedKey;
  final String? userId;
  factory ServerProfile.fromJson(Json j) => ServerProfile(
    id: j['id'],
    name: j['name'],
    url: j['url'],
    email: j['email'],
    authentication: Authentication.values.byName(j['authentication']),
    admin: j['admin'] == true,
    apiKeyId: j['apiKeyId'] as String?,
    managedKey: j['managedKey'] == true,
    userId: j['userId'] as String?,
  );
  Json toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'email': email,
    'authentication': authentication.name,
    'admin': admin,
    'apiKeyId': apiKeyId,
    'managedKey': managedKey,
    'userId': userId,
  };
  static String identity(Uri url, String userId) =>
      sha256.convert(utf8.encode('$url\n$userId')).toString();
}

class Book {
  Book(this.json);
  final Json json;
  String get id => text(json['id']);
  String get seriesId => text(json['seriesId']);
  String get libraryId => text(json['libraryId']);
  String get title => text(metadata['title'], text(json['name']));
  String get seriesTitle => text(json['seriesTitle']);
  String get number => text(metadata['number']);
  Json get metadata => object(json['metadata']);
  Json get media => object(json['media']);
  Json get progress => object(json['readProgress']);
  int get pages => integer(media['pagesCount']);
  int get page => integer(progress['page']);
  bool get completed => progress['completed'] == true;
  String get format => text(media['mediaType']).toLowerCase().contains('pdf')
      ? 'pdf'
      : text(media['mediaType']).toLowerCase().contains('epub') ||
            text(media['mediaProfile']).toLowerCase() == 'epub' ||
            text(json['name']).toLowerCase().endsWith('.epub')
      ? 'epub'
      : 'comic';
  double get fraction => completed
      ? 1
      : pages == 0
      ? 0
      : (page / pages).clamp(0, 1);
  Book withProgress(Json? progress) =>
      Book({...json, 'readProgress': progress});
}

class CatalogItem {
  CatalogItem(this.kind, this.json, {this.readListId});
  final String? readListId;
  final String kind;
  final Json json;
  String get id => text(json['id']);
  String get title =>
      text(object(json['metadata'])['title'], text(json['name']));
  String get subtitle => kind == 'books'
      ? text(json['seriesTitle'])
      : '${integer(json['booksCount'], (json['bookIds'] as List?)?.length ?? 0)}';
  String get thumbnail => '/api/v1/$kind/${Uri.encodeComponent(id)}/thumbnail';
  Book get book => Book(json);
}

class CatalogPage {
  CatalogPage(this.items, this.last, this.total);
  final List<CatalogItem> items;
  final bool last;
  final int total;
  factory CatalogPage.parse(String kind, dynamic data) {
    final j = object(data);
    final values = data is List ? data : (j['content'] as List? ?? []);
    return CatalogPage(
      values.map((v) => CatalogItem(kind, object(v))).toList(),
      data is List || j['last'] == true,
      integer(j['totalElements'], values.length),
    );
  }
}

enum ReadingMode { paged, vertical, webtoon }

enum ReadingDirection { ltr, rtl }

class ReaderPreferences {
  const ReaderPreferences({
    this.mode = ReadingMode.paged,
    this.direction = ReadingDirection.ltr,
    this.spread = false,
    this.rotation = 0,
    this.background = 'black',
    this.fit = 'contain',
    this.tapMode = 'default',
    this.tapInversion = 'auto',
    this.preload = 'balanced',
    this.animate = true,
    this.splitWide = 'none',
  });
  final ReadingMode mode;
  final ReadingDirection direction;
  final bool spread;
  final int rotation;
  final String background, fit;
  final String tapMode, tapInversion, preload;
  final bool animate;
  final String splitWide;
  factory ReaderPreferences.fromJson(Json j) => ReaderPreferences(
    mode: ReadingMode.values.firstWhere(
      (v) => v.name == j['mode'],
      orElse: () => ReadingMode.paged,
    ),
    direction: j['direction'] == 'rtl'
        ? ReadingDirection.rtl
        : ReadingDirection.ltr,
    spread: j['spread'] == true,
    rotation: integer(j['rotation']),
    background: text(j['background'], 'black'),
    fit: text(j['fit'], 'contain'),
    tapMode: text(j['tapMode'], 'default'),
    tapInversion: text(j['tapInversion'], 'auto'),
    preload: text(j['preload'], 'balanced'),
    animate: j['animate'] != false,
    splitWide: text(j['splitWide'], 'none'),
  );
  Json toJson() => {
    'mode': mode.name,
    'direction': direction.name,
    'spread': spread,
    'rotation': rotation,
    'background': background,
    'fit': fit,
    'tapMode': tapMode,
    'tapInversion': tapInversion,
    'preload': preload,
    'animate': animate,
    'splitWide': splitWide,
  };
  ReaderPreferences copy({
    ReadingMode? mode,
    ReadingDirection? direction,
    bool? spread,
    int? rotation,
    String? background,
    String? fit,
    String? tapMode,
    String? tapInversion,
    String? preload,
    bool? animate,
    String? splitWide,
  }) => ReaderPreferences(
    mode: mode ?? this.mode,
    direction: direction ?? this.direction,
    spread: spread ?? this.spread,
    rotation: rotation ?? this.rotation,
    background: background ?? this.background,
    fit: fit ?? this.fit,
    tapMode: tapMode ?? this.tapMode,
    tapInversion: tapInversion ?? this.tapInversion,
    preload: preload ?? this.preload,
    animate: animate ?? this.animate,
    splitWide: splitWide ?? this.splitWide,
  );
}
