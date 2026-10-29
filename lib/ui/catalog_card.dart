import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/browse_preferences.dart';

/// Shared by the live catalog and the settings preview.
class CatalogCard extends StatelessWidget {
  const CatalogCard({
    super.key,
    required this.preferences,
    required this.coverBuilder,
    required this.title,
    required this.detail,
    this.subtitle,
    this.unread = false,
    this.unreadCount = 0,
    this.completed = false,
    this.progress = 0,
  });
  final BrowsePreferences preferences;
  final Widget Function(Widget Function(Widget image) frame) coverBuilder;
  final String title, detail;
  final String? subtitle;
  final bool unread, completed;
  final int unreadCount;
  final double progress;

  Widget _text(BuildContext context, {bool overlay = false}) => Padding(
    padding: EdgeInsets.all(overlay ? 8 : 2),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (subtitle != null && preferences[BrowseOption.seriesTitle])
          Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: overlay ? Colors.white70 : Theme.of(context).hintColor,
            ),
          ),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: overlay ? Colors.white : null,
          ),
        ),
        Text(
          detail,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: overlay ? Colors.white70 : Theme.of(context).hintColor,
          ),
        ),
      ],
    ),
  );

  Widget _frame(BuildContext context, Widget image) => Align(
    alignment: Alignment.bottomCenter,
    child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        boxShadow: preferences[BrowseOption.shadow]
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .16),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit:
              preferences[BrowseOption.preserveAspectRatio] &&
                  !preferences.overlaysText
              ? StackFit.loose
              : StackFit.expand,
          children: [
            if (unread && preferences[BrowseOption.blurUnread])
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: image,
              )
            else
              image,
            if (preferences.overlaysText)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xdd000000)],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: _text(context, overlay: true),
                  ),
                ),
              ),
            if (preferences[BrowseOption.badges] &&
                (completed || unreadCount > 0))
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0xdd1c1c1e),
                    borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(6),
                    ),
                  ),
                  child: completed
                      ? const Icon(
                          CupertinoIcons.check_mark,
                          size: 12,
                          color: Colors.white,
                        )
                      : Text(
                          '$unreadCount',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: coverBuilder((image) => _frame(context, image))),
      if (preferences[BrowseOption.progress] &&
          progress > 0 &&
          progress < 1) ...[
        const SizedBox(height: 5),
        LinearProgressIndicator(value: progress, minHeight: 3),
      ],
      if (!preferences.overlaysText && !preferences.hidesText) ...[
        const SizedBox(height: 8),
        _text(context),
      ],
    ],
  );
}
