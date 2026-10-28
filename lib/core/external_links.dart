import 'package:url_launcher/url_launcher.dart';

bool isExternalWebLink(Uri uri) =>
    (uri.scheme == 'https' || uri.scheme == 'http') &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;

/// System browsing is a distinct user action, with no Komga request headers.
Future<bool> openExternalWebLink(Uri uri) async {
  if (!isExternalWebLink(uri)) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
