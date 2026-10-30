import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../core/reader_defaults.dart';
import '../../core/store.dart';
import '../../ui/common.dart';
import '../../ui/section_scroll_view.dart';
import '../../ui/strings.dart';
import 'settings_style.dart';

enum PreferenceEditor { slider, number, stepper }

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
    this.invertBool = false,
    this.readValue,
    this.writeValue,
    this.captionValue,
    this.formatValue,
    this.choiceIcons,
    this.editor = PreferenceEditor.slider,
    this.unit,
  });
  final PreferenceEditor editor;
  final String? unit;
  final String key, title, section;
  final String? bucket, caption;
  final Object initial;
  final Map<Object, String>? choices;
  final double? min, max;
  final double step;
  final bool Function(LocalStore)? visible, enabled;
  final bool confirmEnable, invertBool;
  final Object Function(LocalStore)? readValue;
  final void Function(LocalStore, Object)? writeValue;
  final String Function(LocalStore)? captionValue;
  final String Function(num)? formatValue;
  final Map<Object, IconData>? choiceIcons;
  Object read(LocalStore store) {
    if (readValue != null) return readValue!(store);
    final value = bucket == null
        ? store.setting<dynamic>(key)
        : object(store.setting<dynamic>(bucket!))[key];
    if (choices != null) {
      return choices!.containsKey(value) ? value as Object : initial;
    }
    if (initial is bool) {
      final stored = value is bool ? value : initial as bool;
      return invertBool ? !stored : stored;
    }
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
    if (writeValue != null) {
      writeValue!(store, value);
      return;
    }
    if (invertBool) value = !(value as bool);
    if (bucket == null) {
      store.setSetting(key, value);
    } else {
      updateReaderDefaults(store, bucket!, {key: value});
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
    this.decorateGroups = true,
    this.sectionTrailing = const {},
    this.sectionFooters = const {},
  });
  final String title;
  final LocalStore store;
  final List<PreferenceSpec> specs;
  final void Function(String key)? onChanged;
  final Widget? header, footer;
  final Map<String, List<Widget>> sectionTrailing;
  final Map<String, String> sectionFooters;
  final bool embedded, decorateGroups;
  @override
  State<PreferencePage> createState() => _PreferencePageState();
}

class _PreferencePageState extends State<PreferencePage> {
  void _write(PreferenceSpec spec, Object value) {
    setState(() => spec.write(widget.store, value));
    widget.onChanged?.call(spec.key);
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: settingsTheme(Theme.of(context)),
    child: Builder(builder: _content),
  );

  Widget _content(BuildContext context) {
    final groups = <String, List<PreferenceSpec>>{};
    var section = '';
    for (final spec in widget.specs) {
      if (spec.section.isNotEmpty) section = spec.section;
      if (spec.visible?.call(widget.store) == false) continue;
      groups.putIfAbsent(section, () => []).add(spec);
    }
    final content = <Widget>[
      ?widget.header,
      for (final group in groups.entries) ...[
        if (group.key.trim().isNotEmpty) SettingsHeading(group.key),
        _group(
          child: Column(
            children: [
              for (var i = 0; i < group.value.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 20, endIndent: 20),
                _control(context, group.value[i]),
              ],
              ...?widget.sectionTrailing[group.key],
            ],
          ),
        ),
        if (widget.sectionFooters[group.key] case final caption?)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              tr(context, caption),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (widget.decorateGroups) const SizedBox(height: 28),
      ],
      ?widget.footer,
    ];
    if (widget.embedded) {
      return Column(mainAxisSize: MainAxisSize.min, children: content);
    }
    return SettingsScaffold(
      title: widget.title,
      body: SectionScrollView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
        children: content,
      ),
    );
  }

  Widget _group({required Widget child}) => widget.decorateGroups
      ? Card(clipBehavior: Clip.antiAlias, child: child)
      : child;

  Widget _control(BuildContext context, PreferenceSpec spec) {
    final value = spec.read(widget.store);
    final enabled = spec.enabled?.call(widget.store) != false;
    final caption = spec.captionValue?.call(widget.store) ?? spec.caption;
    final key = ValueKey('preference:${spec.bucket ?? ''}:${spec.key}');
    if (value is bool) {
      return SwitchListTile.adaptive(
        key: key,
        title: Text(tr(context, spec.title)),
        subtitle: caption == null ? null : Text(tr(context, caption)),
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
      return Builder(
        key: key,
        builder: (rowContext) => InkWell(
          onTap: !enabled
              ? null
              : () async {
                  final chosen = await chooseValue(
                    rowContext,
                    title: spec.title,
                    selected: value,
                    choices: spec.choices!,
                    anchored: true,
                  );
                  if (chosen != null && mounted) _write(spec, chosen);
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, box) {
                    final label = Text(
                      tr(context, spec.title),
                      style: const TextStyle(fontSize: 17),
                    );
                    final selected = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (spec.choiceIcons?[value] case final icon?) ...[
                          Icon(icon, size: 19),
                          const SizedBox(width: 4),
                        ],
                        Flexible(
                          child: Text(
                            tr(context, spec.choices![value]!),
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              fontSize: 17,
                              color: enabled
                                  ? Theme.of(context).colorScheme.onSurface
                                  : Theme.of(context).disabledColor,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.unfold_more, size: 17),
                      ],
                    );
                    if (box.maxWidth < 360) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          label,
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: selected,
                          ),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: label),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: selected,
                          ),
                        ),
                      ],
                    );
                  },
                ),
                if (caption != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      tr(context, caption),
                      style: Theme.of(context).listTileTheme.subtitleTextStyle,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (value is num && spec.editor != PreferenceEditor.slider) {
      final control = spec.editor == PreferenceEditor.number
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 72,
                  child: TextFormField(
                    key: ValueKey('input:${spec.key}'),
                    initialValue: '${value.round()}',
                    enabled: enabled,
                    textAlign: TextAlign.end,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.all(8),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (raw) {
                      final number = int.tryParse(raw);
                      if (number != null &&
                          number >= (spec.min ?? 0) &&
                          number <= (spec.max ?? double.maxFinite)) {
                        _write(spec, number);
                      }
                    },
                  ),
                ),
                if (spec.unit != null) ...[
                  const SizedBox(width: 6),
                  Text(spec.unit!),
                ],
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: tr(context, 'Decrease'),
                  onPressed: enabled && value > (spec.min ?? 0)
                      ? () => _write(spec, value.toInt() - 1)
                      : null,
                  icon: const Icon(Icons.remove, size: 18),
                ),
                Text('$value'),
                IconButton(
                  tooltip: tr(context, 'Increase'),
                  onPressed: enabled && value < (spec.max ?? 5)
                      ? () => _write(spec, value.toInt() + 1)
                      : null,
                  icon: const Icon(Icons.add, size: 18),
                ),
              ],
            );
      return Padding(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr(context, spec.title),
                    style: const TextStyle(fontSize: 17),
                  ),
                ),
                const SizedBox(width: 12),
                control,
              ],
            ),
            if (caption != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  tr(context, caption),
                  style: Theme.of(context).listTileTheme.subtitleTextStyle,
                ),
              ),
          ],
        ),
      );
    }
    if (value is num && spec.min != null && spec.max != null) {
      return Padding(
        key: key,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(tr(context, spec.title))),
                Text(
                  spec.formatValue?.call(value) ??
                      (value is int ? '$value' : value.toStringAsFixed(2)),
                  style: const TextStyle(color: Color(0xff8e8e93)),
                ),
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
            if (caption != null)
              Text(
                tr(context, caption),
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
