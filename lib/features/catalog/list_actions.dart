import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

Future<String?> askName(BuildContext context, String title) async {
  final field = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, title)),
        content: TextField(
          controller: field,
          autofocus: true,
          decoration: InputDecoration(labelText: tr(context, 'Name')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (field.text.trim().isNotEmpty) {
                Navigator.pop(context, field.text.trim());
              }
            },
            child: Text(tr(context, 'Create')),
          ),
        ],
      ),
    );
  } finally {
    field.dispose();
  }
}

Future<void> addToList(
  BuildContext context,
  Repository repository,
  String kind,
  String entryId,
) async {
  try {
    final data = await repository.api.request(
      '/api/v1/$kind',
      query: {'unpaged': true, 'sort': 'name,asc'},
    );
    final lists = CatalogPage.parse(kind, data).items;
    if (!context.mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(CupertinoIcons.add_circled),
              title: Text(tr(context, 'Create New List')),
              onTap: () => Navigator.pop(context, '__new__'),
            ),
            for (final list in lists)
              ListTile(
                title: Text(list.title),
                onTap: () => Navigator.pop(context, list.id),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !context.mounted) return;
    final idsKey = kind == 'readlists' ? 'bookIds' : 'seriesIds';
    if (selected == '__new__') {
      final name = await askName(context, 'Create New List');
      if (name == null) return;
      await repository.api.request(
        '/api/v1/$kind',
        method: 'POST',
        body: {
          'name': name,
          'ordered': true,
          if (kind == 'readlists') 'summary': '',
          idsKey: [entryId],
        },
      );
    } else {
      final current = object(
        await repository.api.request(
          '/api/v1/$kind/${Uri.encodeComponent(selected)}',
        ),
      );
      final ids = <String>{
        ...(current[idsKey] as List? ?? []).map((v) => '$v'),
        entryId,
      };
      await repository.api.request(
        '/api/v1/$kind/${Uri.encodeComponent(selected)}',
        method: 'PATCH',
        body: {idsKey: ids.toList()},
      );
    }
    repository.refreshContent();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr(context, 'Added to List'))));
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
