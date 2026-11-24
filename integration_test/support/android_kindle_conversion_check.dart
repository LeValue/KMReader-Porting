import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

void verifyAndroidKindleConversion() {
  testWidgets('Android Kindle worker converts a synthetic book with artwork', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final cache = await getTemporaryDirectory();
      final work = await cache.createTemp('kindle-conversion-');
      try {
        await File('${work.path}/fixture.kfx')
            .writeAsBytes(ZLibCodec().decode(base64Decode(_kfxFixture)));
        await File('${work.path}/receipt.json').writeAsString(
          jsonEncode({
            'resources': [
              {'file': 'fixture.kfx', 'type': 'KINDLE_MAIN_BASE'},
            ],
          }),
        );
        const worker = MethodChannel('dev.levalue.kmreader/kindle');
        final reply = await worker.invokeMethod<String>('prepare', {
          'directory': work.path,
        });
        final result = jsonDecode(reply ?? '{}') as Map<String, dynamic>;
        expect(result['ok'], isTrue, reason: reply);
        final epub = ZipDecoder().decodeBytes(
          await File('${work.path}/ready.epub').readAsBytes(),
        );
        expect(epub.findFile('META-INF/kmreader-kindle.json'), isNotNull);
        expect(epub.findFile('OEBPS/synthetic_cover_bytes.jpg'), isNotNull);
      } finally {
        await work.delete(recursive: true);
      }
    });
  }, skip: !Platform.isAndroid);
}

// Compressed output of synthetic_progressive_kfx(sections=1, cover=True).
const _kfxFixture =
    'eJzt3FtQE1cYB/Dz5SQk4VINF4sOlM0KFZ0MDSFIYOx0NGIrnWq1tpV6yWzCgtFIcBPRtONMUbwx'
    'Iw4qLahVsN4fOlVrq7Zlitrr+KK2Kjql2rs+dLDVXh/oCQacWuntqQ//Zf5z5nz5fmf3W97XPXXK'
    'DB0z6xjLJMZsjLHZYtWJ9F+z+1fOmJ5u7wtj6xxR56LeFNsb3bF+UTOJtMT2Oex23Szydqxui9Xn'
    'inN2ivVqrP5ArO4R9XbRnz7x1t6bfWu9TOzad5/WrejuWiNzz6qO5u6N9Q3lZZ5QZKE3GAittMaL'
    '+qzVHcfWhlRf2B+s9thXh8JBLeKxN64PRarD89Sw3+fxBWtVrbH5joLHGwmroegtunfz1iF8s8S3'
    'SPwlazLfZt3Lt1uP8Tarj2+VhzL9GZky9WelWc8tUCMl8oLKpVVqtadG8S1QqlSPOCokbi3bapXA'
    'YrVElpfZ/tCn1NQE/D6l7/H+rrdGiQSCSoUnNE/JH2gaW+yo9Dq9rkKH3aXkqxX5Y9WKAkV12FXV'
    'VeCyu4oLnQVFRd6KP93Yp/WfUb04EFg2p3TKjHJiabEXe+7WxH0voJNaG7c9+th0ValQNalGC1Zp'
    'aijkr1WlgZfWsNwfpt/qH5841U373rpEBzXy0P5DGp/N92p87uBnb6ZXRBOt62jqXk/bNbqHtmrk'
    'plc1/hcPRIZrfR20oYMMn4ntJdpipShPoqZGMpxyKzX+cDAQlEL+6nD0+YKSPU8a7/Op1WF/ieTz'
    'h8Mn2mySeqouTypdGJwvaj3bW57PkwABAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB'
    'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAe+Ag34G482LdPiglfo+oDFoU0fTeToi0VEr'
    'XaAj8rgeOjr4gd2bqF2jTNqlcQ/fLetm8j0yr79re++F3stsaNmkyZMYEWMk/ljvJeZmprg4Y5zB'
    'ZDQazWZTfGJqUmJCQuLw5JQhqZkjsu7LHJGRIWXnjZJk28iMjNyi0TZ7vtPpzBpV/KDLMS6vwOmI'
    'HkJmszkxITE9KSndYc2wOv711fsOs5h4vRiAZKazELdQ70mWJZ7TQH1X/6dtSMf1hjijyRyfIBoO'
    'D2U64lyn5waDXi9+XSZ+Z3qLIdmaPz4uZZpilBelOuqa2k0jJxzoTJt+uie7wKstN8cPuzd9+Iic'
    '+0fljh7jLBxb5CoucU8snfTwI5PLnpjx5FNPzyx/xlehVlbN888PhRfXLlkaeXZF/cpVq9esbdiw'
    'cVPzCy+2tG7e8fLOXbv37N23/+Ch1w6//saRo8eOnzj57nvvf/DhR2fOfvzJufMXui5e+fyLL7/6'
    '+ptvr167/v0PN27++NPPv/wanYsYp/7rrnNZxFw6vZ7rjdG5SLck2mDRG6z5ccnjpxmVRSmyo86U'
    'OqGp/UCneWTB9J40r3Y6fli280rO9ehofZP9s8GW/6fJBga7PddFlshJ/PO4hT3Ebo7J3dGx9Mbx'
    'htw2HYIgCIIgCIIgCIIgCIIgCIIgCIIgCIIgCPK/ypDert8B5yM/Ug==';
