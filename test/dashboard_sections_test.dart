import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/models.dart';
import 'package:kmreader/features/catalog/dashboard.dart';

void main() {
  test(
    'recently read and released use upstream filters with library scope',
    () {
      final read = DashboardQuery(
        'dashboard.recentlyReadBooks',
        libraryId: 'library',
      );
      expect(read.kind, 'books');
      expect(read.path, isNull);
      expect(read.sort, 'readProgress.readDate,desc');
      final conditions = read.condition!['allOf'] as List;
      expect(conditions, [
        {
          'readStatus': {'operator': 'is', 'value': 'READ'},
        },
        {
          'libraryId': {'operator': 'is', 'value': 'library'},
        },
      ]);
      final released = DashboardQuery(
        'dashboard.recentlyReleasedBooks',
        now: DateTime(2024, 3, 31, 12),
      );
      expect(released.sort, 'metadata.releaseDate,desc');
      final filter = object(released.condition!['releaseDate']);
      expect(filter['operator'], 'after');
      final cutoff = DateTime.parse(filter['dateTime']).toLocal();
      expect(cutoff, DateTime(2024, 2, 29));
      expect(
        dashboardSections,
        containsAll([
          'dashboard.recentlyReadBooks',
          'dashboard.recentlyReleasedBooks',
        ]),
      );
      expect(
        dashboardCardKinds.keys,
        containsAll(['large', 'medium', 'small', 'horizontal']),
      );
    },
  );
}
