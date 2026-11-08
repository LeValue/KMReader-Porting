import 'dart:convert';

import 'package:http/http.dart' as http;

http.Response? kindleWebFixture(http.Request request) {
  switch (request.url.path) {
    case '/ap/exchangetoken/cookies':
      return http.Response(
        jsonEncode({
          'response': {
            'tokens': {
              'cookies': {
                '.amazon.it': [
                  {'Name': 'session-id', 'Value': 'synthetic-cookie'},
                ],
              },
            },
          },
        }),
        200,
      );
    case '/sendtokindle/extension/checkAuth':
      return http.Response('{"isAuthed":true}', 200);
    case '/sendtokindle/empty':
      return http.Response(
        "<input name='csrfToken' value='synthetic-csrf' />",
        200,
      );
  }
  return null;
}
