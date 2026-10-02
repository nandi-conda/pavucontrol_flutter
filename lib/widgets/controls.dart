import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../pulse/model.dart';

const double _sliderPad = 10;

/// Volume slider(s) in the pavucontrol style: one locked slider, or one per channel.
class VolumeControl extends StatefulWidget {
  const VolumeControl({
    super.key,
    required this.volume,
    required this.locked,
    required this.onChanged,
    this.baseVolume = volumeNorm,
    this.showDb = true,
    this.muted = false,
  });

  final ChannelVolumes volume;
  final bool locked;
  final int baseVolume;
  final bool showDb;
  final bool muted;
  final ValueChanged<List<int>> onChanged;

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  List<int>? _local; // while dragging / until the server catches up
  Timer? _settle;

  List<int> get _values => _local ?? widget.volume.values;

  @override
  void didUpdateWidget(VolumeControl old) {
    super.didUpdateWidget(old);
    if (_local != null && _settle == null && _listEq(_local!, widget.volume.values)) _local = null;
  }

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 1) return false;
    }
    return true;
  }

  void _set(List<int> v) {
    _settle?.cancel();
    _settle = null;
    setState(() => _local = v);
    widget.onChanged(v);
  }

  void _end() {
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 500), () {
      _settle = null;
      if (mounted) setState(() => _local = null);
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vals = _values;
    if (vals.isEmpty) return const SizedBox.shrink();
    final cur = ChannelVolumes(widget.volume.channels, vals);
    if (widget.locked || vals.length == 1) {
      return _row(context, null, cur.max, (v) => _set(cur.scaledTo(v)));
    }
    return Column(
      children: [
        for (var i = 0; i < vals.length; i++)
          _row(context, prettyChannel(widget.volume.channels[i]), vals[i], (v) {
            final next = [...vals]..[i] = v;
            _set(next);
          }),
      ],
    );
  }

  /// Mouse wheel over a slider: 5% per notch (1% with Shift). Claims the event so
  /// the surrounding list doesn't scroll at the same time.
  void _onScroll(PointerSignalEvent e, int value, ValueChanged<int> onChanged) {
    if (e is! PointerScrollEvent) return;
    final dy = e.scrollDelta.dy != 0 ? e.scrollDelta.dy : e.scrollDelta.dx;
    if (dy == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (_) {
      final shift = HardwareKeyboard.instance.isShiftPressed;
      final step = (volumeNorm * (shift ? 0.01 : 0.05)).round();
      final ceiling = math.max(volumeUiMax, value);
      final next = (value + (dy < 0 ? step : -step)).clamp(0, ceiling);
      if (next == value) return;
      onChanged(next);
      _end();
    });
  }

  Widget _row(BuildContext context, String? label, int value, ValueChanged<int> onChanged) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall!;
    final faded = small.copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 10.5);
    final max = math.max(volumeUiMax, value);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null)
          SizedBox(
            width: 92,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(label, style: small, overflow: TextOverflow.ellipsis),
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final track = box.maxWidth - 2 * _sliderPad;
              Widget mark(int at, String text) => Positioned(
                left: at == 0 ? _sliderPad - 1 : _sliderPad + track * at / max - 60,
                width: 120,
                top: 26,
                child: Column(
                  crossAxisAlignment: at == 0 ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                  children: [
                    Container(width: 1, height: 4, color: theme.colorScheme.outline),
                    Text(text, style: faded, textAlign: TextAlign.center, maxLines: 1),
                  ],
                ),
              );
              return Listener(
                behavior: HitTestBehavior.opaque,
                onPointerSignal: (e) => _onScroll(e, value, onChanged),
                child: SizedBox(
                  height: 50,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      mark(0, 'Silence'),
                      if (widget.baseVolume != volumeNorm && widget.baseVolume > 0) mark(widget.baseVolume, 'Base'),
                      mark(volumeNorm, widget.showDb ? '100% (0 dB)' : '100%'),
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: 28,
                        child: Opacity(
                          opacity: widget.muted ? 0.45 : 1,
                          child: Slider(
                            padding: const EdgeInsets.symmetric(horizontal: _sliderPad),
                            min: 0,
                            max: max.toDouble(),
                            value: value.clamp(0, max).toDouble(),
                            onChanged: (v) => onChanged(v.round()),
                            onChangeEnd: (_) => _end(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        SizedBox(
          width: 48,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(formatPercent(value), textAlign: TextAlign.right, style: theme.textTheme.bodyMedium),
          ),
        ),
        if (widget.showDb)
          SizedBox(
            width: 78,
            child: Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(formatDb(value), textAlign: TextAlign.right, style: small),
            ),
          ),
      ],
    );
  }
}

/// Thin level meter fed by a peak stream. Repaints directly — no implicit animation.
class PeakMeter extends StatefulWidget {
  const PeakMeter({super.key, required this.source, this.trailing = 126});
  final Stream<double> Function() source;

  /// Width of the percent/dB columns so the meter lines up with the slider track.
  final double trailing;

  @override
  State<PeakMeter> createState() => _PeakMeterState();
}

class _PeakMeterState extends State<PeakMeter> {
  final _level = ValueNotifier<double>(0);
  StreamSubscription<double>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.source().listen((p) {
      // Map to the same cubic scale as the volume sliders, with pavucontrol-style decay.
      final v = math.pow(p, 1 / 3).toDouble();
      final cur = _level.value;
      _level.value = v >= cur ? v : math.max(v, cur - 0.04);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _level.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(left: _sliderPad, right: _sliderPad + widget.trailing),
      child: SizedBox(
        height: 5,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _MeterPainter(_level, scheme.surfaceContainerHighest, scheme.primary),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.level, this.bg, this.fg) : super(repaint: level);
  final ValueNotifier<double> level;
  final Color bg, fg;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, r), Paint()..color = bg);
    final w = size.width * level.value.clamp(0.0, 1.0);
    if (w > 0) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, size.height), r), Paint()..color = fg);
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.bg != bg || old.fg != fg || old.level != level;
}

/// Small square toggle button (mute / lock / fallback).
class ToggleIcon extends StatelessWidget {
  const ToggleIcon({
    super.key,
    required this.selected,
    required this.icon,
    required this.selectedIcon,
    required this.tooltip,
    required this.onChanged,
  });

  final bool selected;
  final IconData icon;
  final IconData selectedIcon;
  final String tooltip;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: tooltip,
      toggled: selected,
      child: IconButton(
        isSelected: selected,
        icon: Icon(icon, size: 18),
        selectedIcon: Icon(selectedIcon, size: 18),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          fixedSize: const Size(32, 32),
          minimumSize: const Size(32, 32),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          backgroundColor: selected ? scheme.secondaryContainer : null,
          foregroundColor: scheme.onSurfaceVariant,
          splashFactory: NoSplash.splashFactory,
        ),
        onPressed: () => onChanged(!selected),
      ),
    );
  }
}

/// Resolves freedesktop icon names from hicolor / pixmaps / flatpak exports.
class AppIcon extends StatelessWidget {
  const AppIcon({super.key, required this.name, required this.fallback, this.size = 32});
  final String name;
  final IconData fallback;
  final double size;

  static final Map<String, File?> _cache = {};

  static File? _find(String name) {
    if (name.isEmpty || name.contains('/') && !name.startsWith('/')) return null;
    return _cache.putIfAbsent(name, () {
      if (name.startsWith('/')) {
        final f = File(name);
        return f.existsSync() ? f : null;
      }
      final home = Platform.environment['HOME'] ?? '';
      final roots = [
        '$home/.local/share/icons/hicolor',
        '$home/.local/share/flatpak/exports/share/icons/hicolor',
        '/var/lib/flatpak/exports/share/icons/hicolor',
        '/usr/local/share/icons/hicolor',
        '/usr/share/icons/hicolor',
      ];
      const sizes = ['48x48', '64x64', '32x32', '128x128', '256x256', 'scalable'];
      for (final r in roots) {
        for (final s in sizes) {
          for (final ext in ['png', 'svg']) {
            final f = File('$r/$s/apps/$name.$ext');
            if (f.existsSync()) return f;
          }
        }
      }
      for (final ext in ['png', 'svg']) {
        final f = File('/usr/share/pixmaps/$name.$ext');
        if (f.existsSync()) return f;
      }
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final f = _find(name);
    final fb = Icon(fallback, size: size * 0.8, color: Theme.of(context).colorScheme.onSurfaceVariant);
    Widget child;
    if (f == null) {
      child = fb;
    } else if (f.path.endsWith('.svg')) {
      child = SvgPicture.file(f, width: size, height: size, placeholderBuilder: (_) => fb);
    } else {
      child = Image.file(f, width: size, height: size, errorBuilder: (_, _, _) => fb, gaplessPlayback: true);
    }
    return SizedBox(
      width: size,
      height: size,
      child: Center(child: child),
    );
  }
}

IconData deviceIconFor(String iconName, DeviceKind kind) {
  final n = iconName.toLowerCase();
  if (n.contains('headset')) return Icons.headset_mic;
  if (n.contains('headphone')) return Icons.headphones;
  if (n.contains('bluetooth')) return Icons.bluetooth_audio;
  if (n.contains('hdmi') || n.contains('video') || n.contains('display')) return Icons.tv;
  if (n.contains('webcam') || n.contains('camera')) return Icons.videocam;
  if (kind == DeviceKind.source || n.contains('microphone')) return Icons.mic;
  return Icons.speaker;
}
