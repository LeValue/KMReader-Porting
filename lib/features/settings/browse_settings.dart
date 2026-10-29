import 'settings_style.dart';

import 'package:flutter/material.dart';

import '../../core/browse_preferences.dart';
import '../../ui/catalog_card.dart';
import '../../ui/strings.dart';

const _labels = {
  BrowseOption.ignoreSearchFilters: 'searchIgnoreFilters',
  BrowseOption.textOverlay: 'cardTextOverlay',
  BrowseOption.coverOnly: 'coverOnlyCards',
  BrowseOption.seriesTitle: 'showBookCardSeriesTitles',
  BrowseOption.preserveAspectRatio: 'preserveCoverAspectRatio',
  BrowseOption.shadow: 'coverShowShadow',
  BrowseOption.badges: 'coverShowUnreadIndicator',
  BrowseOption.blurUnread: 'coverBlurUnread',
  BrowseOption.progress: 'coverShowProgressBar',
};

class BrowseSettingsPage extends StatelessWidget {
  const BrowseSettingsPage({super.key, required this.preferences});
  final BrowsePreferences preferences;

  Widget _toggle(BuildContext context, BrowseOption option) =>
      SwitchListTile.adaptive(
        key: ValueKey(option),
        title: Text(
          tr(context, 'settings.appearance.${_labels[option]}.title'),
        ),
        subtitle: Text(
          tr(context, 'settings.appearance.${_labels[option]}.caption'),
        ),
        value: preferences[option],
        onChanged: (value) => preferences.set(option, value),
      );

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: 'settings.browse.title',
    body: ListenableBuilder(
      listenable: preferences,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(22),
        children: [
          _heading(context, 'settings.appearance.search'),
          Card(child: _toggle(context, BrowseOption.ignoreSearchFilters)),
          const SizedBox(height: 28),
          _heading(context, 'settings.appearance.cards'),
          Card(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final height = (constraints.maxWidth / 3 * 1.55 + 90)
                          .clamp(200.0, 480.0);
                      return SizedBox(
                        height: height,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < 3; i++) ...[
                              if (i > 0) const SizedBox(width: 16),
                              Expanded(
                                child: CatalogCard(
                                  preferences: preferences,
                                  coverBuilder: (frame) => frame(
                                    _PreviewCover(
                                      preserve:
                                          preferences[BrowseOption
                                              .preserveAspectRatio] &&
                                          !preferences.overlaysText,
                                      ratio: [1.0, .6, 1.0][i],
                                    ),
                                  ),
                                  title: i == 0
                                      ? 'Series Title'
                                      : '#${i == 1 ? 12 : 1} - Book Title',
                                  subtitle: i == 0 ? null : 'Series Title',
                                  detail: i == 0
                                      ? '12 ${tr(context, 'Books')}'
                                      : '200 ${tr(context, 'Pages')}',
                                  unread: i == 0,
                                  unreadCount: i == 0 ? 12 : 0,
                                  progress: i == 1 ? .45 : 0,
                                  completed: i == 2,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
                for (final option in BrowseOption.values.skip(1))
                  if (!(preferences.overlaysText &&
                      (option == BrowseOption.coverOnly ||
                          option == BrowseOption.preserveAspectRatio))) ...[
                    const Divider(height: 1, indent: 18, endIndent: 18),
                    _toggle(context, option),
                  ],
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _heading(BuildContext context, String key) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 0, 0, 10),
    child: Text(
      tr(context, key),
      style: TextStyle(color: Theme.of(context).hintColor),
    ),
  );
}

class _PreviewCover extends StatelessWidget {
  const _PreviewCover({required this.preserve, required this.ratio});
  final bool preserve;
  final double ratio;
  @override
  Widget build(BuildContext context) {
    final cover = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Theme.of(context).colorScheme.surfaceContainerHighest
                .withValues(alpha: .5),
            Theme.of(context).colorScheme.surfaceContainerHighest,
          ],
        ),
      ),
    );
    return preserve ? AspectRatio(aspectRatio: ratio, child: cover) : cover;
  }
}
