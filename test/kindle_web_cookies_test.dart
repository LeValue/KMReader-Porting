import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/kindle/web_cookies.dart';

void main() {
  test('host-only expiry preserves the parent-domain authentication grant', () {
    final jar = KindleWebsiteCookies()
      ..exchange({
        '.amazon.it': [
          {'Name': 'session-id', 'Value': '"bound-session"'},
          {'Name': 'session-token', 'Value': '"bound-token"'},
        ],
      });
    final page = Uri.https('www.amazon.it', '/hz/mycd/myx');
    final ajax = Uri.https('www.amazon.it', '/hz/mycd/ajax');
    jar.receive(page, {
      'set-cookie': 'session-id=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/, session-token=; Max-Age=0; Path=/',
    });
    expect(
      jar.header(ajax),
      'session-id=bound-session; session-token=bound-token',
    );
    jar.receive(page, {
      'set-cookie': 'session-token=rotated; Domain=.amazon.it; Path=/; Secure',
    });
    expect(jar.header(ajax), 'session-id=bound-session; session-token=rotated');
    jar.receive(page, {
      'set-cookie': 'session-token=; Domain=.amazon.it; Max-Age=0; Path=/',
    });
    expect(jar.header(ajax), 'session-id=bound-session');
  });
  test(
    'cookie paths, foreign domains and Max-Age precedence follow cookie scope',
    () {
      final jar = KindleWebsiteCookies()
        ..exchange({
          '.amazon.it': [
            {'Name': 'session-id', 'Value': 'parent'},
          ],
          '.evil.invalid': [
            {'Name': 'secret', 'Value': 'never-send'},
          ],
        });
      final page = Uri.https('www.amazon.it', '/hz/mycd/myx');
      jar.receive(page, {
        'set-cookie': 'session-id=path; Path=/hz/mycd; Max-Age=60; Expires=Thu, 01 Jan 1970 00:00:00 GMT, secret=never-send; Domain=evil.invalid; Path=/',
      });
      expect(
        jar.header(Uri.https('www.amazon.it', '/hz/mycd/ajax')),
        'session-id=path; session-id=parent',
      );
      expect(
        jar.header(Uri.https('www.amazon.it', '/hz/mycdbad/ajax')),
        'session-id=parent',
      );
      expect(jar.header(Uri.https('evil.invalid', '/')), isEmpty);
      expect(jar.header(Uri.http('www.amazon.it', '/')), isEmpty);
      jar.receive(page, {'set-cookie': 'session-id=; Max-Age=0'});
      expect(
        jar.header(Uri.https('www.amazon.it', '/hz/mycd/ajax')),
        'session-id=parent',
      );
    },
  );
}
