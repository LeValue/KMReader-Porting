import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/models.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

const readingStatsRanges = {
  'thisWeek': 'This Week',
  'last7Days': 'Last 7 Days',
  'last30Days': 'Last 30 Days',
  'last90Days': 'Last 90 Days',
  'last6Months': 'Last 6 Months',
  'lastYear': 'Last Year',
  'allTime': 'All Time',
};

DateTime readingRangeStart(
  String range,
  DateTime now,
  Iterable<DateTime> known, {
  int firstWeekday = DateTime.monday,
}) {
  final today = DateUtils.dateOnly(now);
  DateTime monthsAgo(int months) {
    final month = DateTime(today.year, today.month - months);
    return DateTime(
      month.year,
      month.month,
      math.min(today.day, DateTime(month.year, month.month + 1, 0).day),
    );
  }

  return switch (range) {
    'thisWeek' => DateTime(
      today.year,
      today.month,
      today.day - (today.weekday - firstWeekday + 7) % 7,
    ),
    'last7Days' => DateTime(today.year, today.month, today.day - 6),
    'last30Days' => DateTime(today.year, today.month, today.day - 29),
    'last90Days' => DateTime(today.year, today.month, today.day - 89),
    'lastYear' => monthsAgo(12),
    'allTime' =>
      known
          .where((d) => !d.isAfter(today))
          .fold(today, (a, b) => b.isBefore(a) ? b : a),
    _ => monthsAgo(6),
  };
}

class ReadingStatsOverview extends StatelessWidget {
  const ReadingStatsOverview({
    super.key,
    required this.data,
    required this.library,
    required this.onScope,
    required this.range,
    required this.onRange,
    this.now,
  });
  final Json data;
  final String library, range;
  final VoidCallback onScope;
  final ValueChanged<String> onRange;
  final DateTime? now;
  @override
  Widget build(BuildContext context) {
    final summary = object(data['summary']);
    final locale = Localizations.localeOf(context).toLanguageTag();
    String count(dynamic n) => (NumberFormat.decimalPattern(
      locale,
    )..maximumFractionDigits = 0).format(n is num ? n : 0);
    String date(dynamic raw, {bool time = false}) {
      final value = DateTime.tryParse(text(raw));
      if (value == null) return '—';
      return time
          ? DateFormat.yMd(locale).add_Hm().format(value.toLocal())
          : DateFormat.yMMMd(locale).format(value.toLocal());
    }

    final metrics = <(String, String, IconData)>[
      (
        'Books Started',
        count(summary['booksStartedReading']),
        CupertinoIcons.book,
      ),
      (
        'Books Completed',
        count(summary['booksCompletedReading']),
        CupertinoIcons.checkmark_circle,
      ),
      ('Pages Read', count(summary['totalPagesRead']), CupertinoIcons.doc_text),
      ('Reading Days', count(summary['readingDays']), CupertinoIcons.calendar),
      (
        'Average Pages per Book',
        count(summary['averagePagesPerBook']),
        CupertinoIcons.chart_bar,
      ),
      ('Total Books', count(summary['totalBooks']), CupertinoIcons.book),
      ('Last Read', date(summary['lastReadAt']), CupertinoIcons.clock),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatsCard(
          child: InkWell(
            onTap: onScope,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 6,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(library, style: const TextStyle(fontSize: 16)),
                      const SizedBox(width: 4),
                      const Icon(Icons.unfold_more, size: 16),
                    ],
                  ),
                  Text(
                    date(data['generatedAt'], time: true),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff8e8e93),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (data['complete'] != true || data['offline'] == true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              tr(
                context,
                data['offline'] == true ? 'Offline Mode' : 'Cached Books Only',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, box) {
            final columns = box.maxWidth >= 800
                ? 5
                : box.maxWidth >= 500
                ? 3
                : 2;
            final width = (box.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final metric in metrics)
                  SizedBox(
                    width: width,
                    child: _StatsCard(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  metric.$3,
                                  size: 13,
                                  color: const Color(0xff8e8e93),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    tr(context, metric.$1),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xff8e8e93),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(
                              metric.$2,
                              style: const TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        ReadingPagesHeatmap(
          data: data,
          range: range,
          onRange: onRange,
          now: now,
        ),
        const SizedBox(height: 16),
        ReadingStatusChart(
          items: (data['statusDistribution'] as List? ?? [])
              .map(object)
              .toList(),
        ),
      ],
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).brightness == Brightness.dark
        ? const Color(0xff1c1c1e)
        : const Color(0xfff5f5f5),
    elevation: 0,
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: child,
  );
}

class ReadingPagesHeatmap extends StatefulWidget {
  const ReadingPagesHeatmap({
    super.key,
    required this.data,
    required this.range,
    required this.onRange,
    this.now,
  });
  final Json data;
  final String range;
  final ValueChanged<String> onRange;
  final DateTime? now;
  @override
  State<ReadingPagesHeatmap> createState() => _ReadingPagesHeatmapState();
}

class _ReadingPagesHeatmapState extends State<ReadingPagesHeatmap> {
  DateTime? _selected;
  @override
  Widget build(BuildContext context) {
    final values = <DateTime, num>{};
    for (final raw in widget.data['readingTimeSeries'] as List? ?? []) {
      final row = object(raw),
          date = DateTime.tryParse(
            text(object(raw)['date'], text(object(raw)['name'])),
          );
      if (date != null) {
        values[DateUtils.dateOnly(date)] = row['value'] as num? ?? 0;
      }
    }
    final today = DateUtils.dateOnly(widget.now ?? DateTime.now());
    final firstWeekday =
        MaterialLocalizations.of(context).firstDayOfWeekIndex == 0
        ? 7
        : MaterialLocalizations.of(context).firstDayOfWeekIndex;
    final start = readingRangeStart(
      widget.range,
      today,
      values.keys,
      firstWeekday: firstWeekday,
    );
    final first = DateTime(
      start.year,
      start.month,
      start.day - (start.weekday - firstWeekday + 7) % 7,
    );
    final weeks = ((today.difference(first).inDays + 1) / 7).ceil();
    final maximum = values.values.fold<num>(0, math.max);
    Color color(num count) => count <= 0
        ? Theme.of(context).colorScheme.onSurface.withValues(alpha: .055)
        : const Color(
            0xff30c95b,
          ).withValues(alpha: .28 + .72 * (maximum > 0 ? count / maximum : 1));
    return _StatsCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr(context, 'Pages Read'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Builder(
                      builder: (row) => TextButton(
                        onPressed: () async {
                          final next = await chooseValue(
                            row,
                            title: 'Pages Read',
                            selected: widget.range,
                            choices: readingStatsRanges,
                            anchored: true,
                          );
                          if (next != null) widget.onRange(next);
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                tr(context, readingStatsRanges[widget.range]!),
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                            const Icon(Icons.unfold_more, size: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 119,
              child: ListView.builder(
                key: ValueKey('heatmap:${widget.range}'),
                scrollDirection: Axis.horizontal,
                primary: false,
                itemExtent: 17,
                itemCount: weeks,
                itemBuilder: (context, week) => Column(
                  children: [
                    for (var day = 0; day < 7; day++)
                      Builder(
                        builder: (context) {
                          final date = DateTime(
                            first.year,
                            first.month,
                            first.day + week * 7 + day,
                          );
                          if (date.isBefore(start) || date.isAfter(today)) {
                            return const SizedBox(width: 17, height: 17);
                          }
                          final count = values[date] ?? 0;
                          final label =
                              '${DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(date)}: $count ${tr(context, 'pages')}';
                          return Tooltip(
                            message: label,
                            child: Semantics(
                              label: label,
                              button: true,
                              selected: _selected == date,
                              child: InkWell(
                                onTap: () => setState(
                                  () => _selected = _selected == date
                                      ? null
                                      : date,
                                ),
                                child: SizedBox(
                                  width: 17,
                                  height: 17,
                                  child: Center(
                                    child: Container(
                                      width: 13,
                                      height: 13,
                                      decoration: BoxDecoration(
                                        color: color(count),
                                        borderRadius: BorderRadius.circular(3),
                                        border: _selected == date
                                            ? Border.all(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurface,
                                              )
                                            : null,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final level in [0.0, .25, .5, .75, 1.0])
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Container(
                      width: 13,
                      height: 13,
                      decoration: BoxDecoration(
                        color: color(level * math.max(1, maximum)),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
              ],
            ),
            if (_selected != null &&
                !_selected!.isBefore(start) &&
                !_selected!.isAfter(today))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(_selected!)}: ${values[_selected] ?? 0} ${tr(context, 'pages')}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ReadingStatusChart extends StatelessWidget {
  const ReadingStatusChart({super.key, required this.items});
  final List<Json> items;
  static const colors = [
    Color(0xff0a84ff),
    Color(0xffff9f0a),
    Color(0xff30c95b),
  ];
  @override
  Widget build(BuildContext context) {
    final counts = [
      for (final name in ['unread', 'inProgress', 'read'])
        items
            .where((i) => i['name'] == name)
            .fold<num>(0, (sum, i) => sum + (i['value'] as num? ?? 0))
            .clamp(0, double.maxFinite)
            .toDouble(),
    ];
    const names = ['Unread', 'In Progress', 'Read'];
    return _StatsCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr(context, 'Read Status'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Center(
              child: SizedBox(
                width: 240,
                height: 240,
                child: Semantics(
                  label: [
                    for (var i = 0; i < 3; i++)
                      '${tr(context, names[i])}: ${counts[i].round()}',
                  ].join(', '),
                  child: CustomPaint(
                    painter: _StatusRing(
                      counts,
                      colors,
                      Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: .08),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 18,
              runSpacing: 8,
              children: [
                for (var i = 0; i < 3; i++)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: colors[i],
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '${tr(context, names[i])} ${counts[i].round()}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusRing extends CustomPainter {
  const _StatusRing(this.values, this.colors, this.empty);
  final List<double> values;
  final List<Color> colors;
  final Color empty;
  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * .2,
        rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final total = values.fold<double>(0, (a, b) => a + b);
    if (total == 0) {
      canvas.drawOval(rect, paint..color = empty);
      return;
    }
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * math.pi * 2;
      if (sweep > 0) {
        canvas.drawArc(
          rect,
          start + math.min(.008, sweep / 4),
          math.max(0, sweep - .016),
          false,
          paint..color = colors[i],
        );
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_StatusRing old) =>
      old.values.toString() != values.toString() || old.empty != empty;
}
