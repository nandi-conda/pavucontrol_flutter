import 'package:flutter/material.dart';

class MenuEntry<T> {
  final T value;
  final String label;
  final bool enabled;
  const MenuEntry(this.value, this.label, {this.enabled = true});
}

/// A GTK-combo-box-like button whose menu pops open instantly (no animation).
class InstantDropdown<T> extends StatelessWidget {
  const InstantDropdown({
    super.key,
    required this.value,
    required this.entries,
    required this.onSelected,
    this.placeholder = '',
    this.maxWidth = 360,
    this.dense = false,
  });

  final T? value;
  final List<MenuEntry<T>> entries;
  final ValueChanged<T> onSelected;
  final String placeholder;
  final double maxWidth;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final current = entries.where((e) => e.value == value).firstOrNull;
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      animated: false,
      consumeOutsideTap: true,
      style: const MenuStyle(visualDensity: VisualDensity.compact),
      menuChildren: [
        for (final e in entries)
          MenuItemButton(
            onPressed: e.enabled ? () => onSelected(e.value) : null,
            leadingIcon: SizedBox(
              width: 18,
              child: e.value == value ? const Icon(Icons.check, size: 16) : null,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Text(e.label, overflow: TextOverflow.ellipsis),
            ),
          ),
      ],
      builder: (context, controller, _) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: dense ? 0 : 4),
            minimumSize: const Size(0, 30),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            side: BorderSide(color: scheme.outlineVariant),
            foregroundColor: scheme.onSurface,
            splashFactory: NoSplash.splashFactory,
          ),
          onPressed: entries.isEmpty ? null : () => controller.isOpen ? controller.close() : controller.open(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(current?.label ?? placeholder, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 6),
              const Icon(Icons.arrow_drop_down, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
