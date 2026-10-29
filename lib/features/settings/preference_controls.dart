import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/store.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';

class PreferenceSpec {
  const PreferenceSpec(
    this.key,
    this.title,
    this.initial, {
    this.section = '',
    this.bucket,
    this.caption,
    this.choices,
    this.min,
    this.max,
    this.step = 1,
    this.visible,
    this.enabled,
    this.confirmEnable = false,
  });
  final String key, title, section;
  final String? bucket, caption;
  final Object initial;
  final Map<Object, String>? choices;
  final double? min, max;
  final double step;
  final bool Function(LocalStore)? visible, enabled;
  final bool confirmEnable;
  Object read(LocalStore store) {
    final value = bucket == null
        ? store.setting<dynamic>(key)
        : object(store.setting<dynamic>(bucket!))[key];
    if (choices != null) {
      return choices!.containsKey(value) ? value as Object : initial;
    }
    if (initial is bool) return value is bool ? value : initial;
    if (initial is num) {
      if (value is! num || !value.isFinite) return initial;
      final number = value.toDouble().clamp(
        min ?? -double.maxFinite,
        max ?? double.maxFinite,
      );
      return initial is int ? number.round() : number;
    }
    return value is String ? value : initial;
  }

  void write(LocalStore store, Object value) {
    if (bucket == null) {
      store.setSetting(key, value);
    } else {
      store.setSetting(bucket!, {
        ...object(store.setting<dynamic>(bucket!)),
        key: value,
      });
    }
  }
}

class PreferencePage extends StatefulWidget {
  const PreferencePage({
    super.key,
    required this.title,
    required this.store,
    required this.specs,
    this.onChanged,
    this.header,
    this.footer,
    this.embedded = false,
  });
  final String title;
  final LocalStore store;
  final List<PreferenceSpec> specs;
  final void Function(String key)? onChanged;
  final Widget? header, footer;
  final bool embedded;
  @override
  State<PreferencePage> createState() => _PreferencePageState();
}

class _PreferencePageState extends State<PreferencePage> {
  void _write(PreferenceSpec spec, Object value) {
    setState(() => spec.write(widget.store, value));
    widget.onChanged?.call(spec.key);
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<PreferenceSpec>>{};
    for (final spec in widget.specs) {
      if (spec.visible?.call(widget.store) == false) continue;
      groups.putIfAbsent(spec.section, () => []).add(spec);
    }
    final content = <Widget>[
      ?widget.header,
      for (final group in groups.entries) ...[
        if (group.key.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 0, 10),
            child: Text(
              tr(context, group.key),
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < group.value.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                _control(context, group.value[i]),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
      ?widget.footer,
    ];
    if (widget.embedded) {
      return Column(mainAxisSize: MainAxisSize.min, children: content);
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, widget.title))),
      body: ListView(padding: const EdgeInsets.all(22), children: content),
    );
  }

  Widget _control(BuildContext context, PreferenceSpec spec) {
    final value = spec.read(widget.store);
    final enabled = spec.enabled?.call(widget.store) != false;
    final key = ValueKey('preference:${spec.bucket ?? ''}:${spec.key}');
    if (value is bool) {
      return SwitchListTile.adaptive(
        key: key,
        title: Text(tr(context, spec.title)),
        subtitle: spec.caption == null
            ? null
            : Text(tr(context, spec.caption!)),
        value: value,
        onChanged: !enabled
            ? null
            : (value) async {
                if (value &&
                    spec.confirmEnable &&
                    !await confirm(
                      context,
                      spec.title,
                      spec.caption ?? spec.title,
                    )) {
                  return;
                }
                if (mounted) _write(spec, value);
              },
      );
    }
    if (spec.choices != null) {
      return ListTile(
        key: key,
        title: Text(tr(context, spec.title)),
        subtitle: Text(tr(context, spec.choices![value]!)),
        trailing: const Icon(Icons.unfold_more, size: 18),
        onTap: !enabled
            ? null
            : () async {
                final chosen = await chooseValue(
                  context,
                  title: spec.title,
                  selected: value,
                  choices: spec.choices!,
                );
                if (chosen != null && mounted) _write(spec, chosen);
              },
      );
    }
    if (value is num && spec.min != null && spec.max != null) {
      return Padding(
        key: key,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(tr(context, spec.title))),
                Text(value is int ? '$value' : value.toStringAsFixed(2)),
              ],
            ),
            Slider(
              value: value.toDouble(),
              min: spec.min!,
              max: spec.max!,
              divisions: ((spec.max! - spec.min!) / spec.step).round().clamp(
                1,
                1000,
              ),
              onChanged: !enabled
                  ? null
                  : (next) =>
                        _write(spec, spec.initial is int ? next.round() : next),
            ),
            if (spec.caption != null)
              Text(
                tr(context, spec.caption!),
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      );
    }
    return ListTile(
      key: key,
      title: Text(tr(context, spec.title)),
      subtitle: Text('$value'),
    );
  }
}
