import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'client.dart';

/// Send-to-Kindle's desktop OAuth client has its own token audience. A reading
/// device bearer isn't a substitute when Firs rejects that authorization.
class KindleSendLoginAttempt {
  KindleSendLoginAttempt({String? verifier, String? state})
    : verifier = verifier ?? kindleRandom(),
      state = state ?? kindleRandom();
  static const clientId =
      '658490dfb190e494030082836775981fa23be0c2425441860352ba0f55915b43002d';
  final String verifier, state;
  Uri get url => Uri.https('www.amazon.com', '/ap/signin', {
    'openid.claimed_id': 'http://specs.openid.net/auth/2.0/identifier_select',
    'openid.identity': 'http://specs.openid.net/auth/2.0/identifier_select',
    'openid.ns': 'http://specs.openid.net/auth/2.0',
    'openid.ns.oa2': 'http://www.amazon.com/ap/ext/oauth/2',
    'openid.mode': 'checkid_setup',
    'openid.oa2.client_id': 'device:$clientId',
    'openid.oa2.scope': 'device_auth_access',
    'openid.oa2.response_type': 'code',
    'openid.oa2.state': state,
    'openid.oa2.code_challenge': base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', ''),
    'openid.oa2.code_challenge_method': 'S256',
    'openid.return_to': 'https://www.amazon.com/gp/sendtokindle',
    'openid.assoc_handle': 'amzn_device_na',
    'accountStatusPolicy': 'P1',
    'pageId': 'amzn_device_common_dark',
  });
  static bool isCallback(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'www.amazon.com' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      uri.path == '/gp/sendtokindle';
  String code(Uri uri) {
    if (!isCallback(uri)) throw const KindleFailure('login_callback');
    final params = Uri(query: '${uri.query}&${uri.fragment}')
        .queryParametersAll;
    final echoed = params['openid.oa2.state'] ?? params['state'];
    if (echoed != null && (echoed.length != 1 || echoed.single != state)) {
      throw const KindleFailure('login_state');
    }
    if (params.containsKey('error') || params.containsKey('openid.oa2.error')) {
      throw const KindleFailure('login_rejected');
    }
    final code = params['openid.oa2.authorization_code'];
    if (code == null ||
        code.length != 1 ||
        code.single.isEmpty ||
        RegExp(r'\s|\x00').hasMatch(code.single)) {
      throw const KindleFailure('login_callback');
    }
    return code.single;
  }
}
