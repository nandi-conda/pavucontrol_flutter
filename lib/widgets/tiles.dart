import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pulse/backend.dart';
import '../pulse/model.dart';
import 'controls.dart';
import 'instant_menu.dart';

const _tilePadding = EdgeInsets.fromLTRB(14, 10, 14, 12);

Future<void> _contextMenu(BuildContext context, Offset at, List<(String, VoidCallback)> items) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final picked = await showMenu<int>(
    context: context,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
    items: [for (var i = 0; i < items.length; i++) PopupMenuItem(value: i, height: 34, child: Text(items[i].$1))],
  );
  if (picked != null) items[picked].$2();
}

class StreamTile extends StatefulWidget {
  const StreamTile({super.key, required this.stream, required this.devices, required this.backend});
  final PaStream stream;
  final List<PaDevice> devices;
  final PulseBackend backend;

  @override
  State<StreamTile> createState() => _StreamTileState();
}

class _StreamTileState extends State<StreamTile> {
  bool _locked = true;

  @override
  Widget build(BuildContext context) {
    final s = widget.stream;
    final be = widget.backend;
    final playback = s.kind == DeviceKind.sink;
    final theme = Theme.of(context);
    final device = widget.devices.where((d) => d.index == s.device).firstOrNull;
    final multi = s.volume.values.length > 1;

    return GestureDetector(
      onSecondaryTapDown: (e) => _contextMenu(context, e.globalPosition, [('Terminate', () => be.killStream(s))]),
      child: Padding(
        padding: _tilePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AppIcon(name: s.iconName, fallback: playback ? Icons.music_note : Icons.mic_none),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: s.appName, style: const TextStyle(fontWeight: FontWeight.bold)),
                      if (s.mediaName.isNotEmpty && s.mediaName != s.appName) TextSpan(text: ': ${s.mediaName}'),
                    ]),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: 8),
                Text(playback ? 'on' : 'from', style: theme.textTheme.bodyMedium),
                const SizedBox(width: 6),
                Flexible(
                  child: InstantDropdown<int>(
                    value: s.device,
                    maxWidth: 260,
                    placeholder: 'Unknown',
                    entries: [for (final d in widget.devices) MenuEntry(d.index, d.description)],
                    onSelected: (i) => be.moveStream(s, widget.devices.firstWhere((d) => d.index == i)),
                  ),
                ),
                const SizedBox(width: 6),
                ToggleIcon(
                  selected: s.mute,
                  icon: Icons.volume_up_outlined,
                  selectedIcon: Icons.volume_off,
                  tooltip: 'Mute audio',
                  onChanged: (m) => be.setStreamMute(s, m),
                ),
                if (multi) ...[
                  const SizedBox(width: 4),
                  ToggleIcon(
                    selected: _locked,
                    icon: Icons.link_off,
                    selectedIcon: Icons.link,
                    tooltip: 'Lock channels together',
                    onChanged: (v) => setState(() => _locked = v),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            if (s.hasVolume)
              VolumeControl(
                volume: s.volume,
                locked: _locked,
                muted: s.mute,
                onChanged: (v) => be.setStreamVolume(s, v),
              ),
            if (device != null)
              PeakMeter(
                key: ValueKey('${device.meterSource}/${playback ? s.index : ''}'),
                source: () => be.meter(device.meterSource, streamIndex: playback ? s.index : null),
              ),
          ],
        ),
      ),
    );
  }
}

class DeviceTile extends StatefulWidget {
  const DeviceTile({super.key, required this.device, required this.isDefault, required this.card, required this.backend});
  final PaDevice device;
  final bool isDefault;
  final PaCard? card;
  final PulseBackend backend;

  @override
  State<DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends State<DeviceTile> {
  bool _locked = true;
  bool _advanced = false;
  final _latency = TextEditingController();
  final _latencyFocus = FocusNode();

  int get _offsetUsec {
    final d = widget.device;
    final p = widget.card?.ports.where((p) => p.name == d.activePort).firstOrNull;
    return p?.latencyOffsetUsec ?? 0;
  }

  @override
  void initState() {
    super.initState();
    _latency.text = (_offsetUsec / 1000).toStringAsFixed(2);
    _latencyFocus.addListener(() {
      if (!_latencyFocus.hasFocus) _commitLatency();
    });
  }

  @override
  void didUpdateWidget(DeviceTile old) {
    super.didUpdateWidget(old);
    if (!_latencyFocus.hasFocus) _latency.text = (_offsetUsec / 1000).toStringAsFixed(2);
  }

  void _commitLatency() {
    final d = widget.device;
    final ms = double.tryParse(_latency.text.trim());
    if (ms == null || widget.card == null || d.activePort == null) return;
    widget.backend.setLatencyOffset(widget.card!.name, d.activePort!, (ms * 1000).round());
  }

  @override
  void dispose() {
    _latency.dispose();
    _latencyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    final be = widget.backend;
    final theme = Theme.of(context);
    final multi = d.volume.values.length > 1;
    final sink = d.kind == DeviceKind.sink;

    return Padding(
      padding: _tilePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(deviceIconFor(d.iconName, d.kind), size: 26, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(d.description,
                    style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
              ),
              ToggleIcon(
                selected: d.mute,
                icon: Icons.volume_up_outlined,
                selectedIcon: Icons.volume_off,
                tooltip: 'Mute audio',
                onChanged: (m) => be.setMute(d, m),
              ),
              if (multi) ...[
                const SizedBox(width: 4),
                ToggleIcon(
                  selected: _locked,
                  icon: Icons.link_off,
                  selectedIcon: Icons.link,
                  tooltip: 'Lock channels together',
                  onChanged: (v) => setState(() => _locked = v),
                ),
              ],
              const SizedBox(width: 4),
              ToggleIcon(
                selected: widget.isDefault,
                icon: Icons.radio_button_unchecked,
                selectedIcon: Icons.check_circle,
                tooltip: 'Set as fallback',
                onChanged: (v) {
                  if (v) be.setDefault(d);
                },
              ),
            ],
          ),
          if (d.ports.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const SizedBox(width: 36),
                Text('Port:', style: theme.textTheme.bodyMedium),
                const SizedBox(width: 8),
                Flexible(
                  child: InstantDropdown<String>(
                    value: d.activePort,
                    entries: [for (final p in d.ports) MenuEntry(p.name, p.label)],
                    onSelected: (p) => be.setPort(d, p),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          VolumeControl(
            volume: d.volume,
            locked: _locked,
            muted: d.mute,
            baseVolume: d.baseVolume,
            showDb: d.decibel,
            onChanged: (v) => be.setVolume(d, v),
          ),
          PeakMeter(
              key: ValueKey(d.meterSource),
              trailing: d.decibel ? 126 : 48,
              source: () => be.meter(d.meterSource)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => setState(() => _advanced = !_advanced),
              icon: Icon(_advanced ? Icons.arrow_drop_down : Icons.arrow_right, size: 20),
              label: const Text('Advanced'),
            ),
          ),
          if (_advanced)
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 2),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Latency offset:', style: theme.textTheme.bodyMedium),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _latency,
                      focusNode: _latencyFocus,
                      enabled: widget.card != null && d.activePort != null,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]'))],
                      onSubmitted: (_) => _commitLatency(),
                      decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                    ),
                  ),
                  Text('ms', style: theme.textTheme.bodyMedium),
                  const SizedBox(width: 16),
                  Text(
                    '${sink ? 'Sink' : 'Source'}: ${d.name}',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class CardTile extends StatelessWidget {
  const CardTile({super.key, required this.card, required this.backend});
  final PaCard card;
  final PulseBackend backend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: _tilePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(deviceIconFor(card.iconName, DeviceKind.sink), size: 26, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(card.description,
                    style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 36),
              Text('Profile:', style: theme.textTheme.bodyMedium),
              const SizedBox(width: 8),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InstantDropdown<String>(
                    value: card.activeProfile,
                    maxWidth: 520,
                    entries: [for (final p in card.profiles) MenuEntry(p.name, p.label)],
                    onSelected: (p) => backend.setCardProfile(card, p),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
