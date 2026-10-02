import 'dart:io';

import 'package:flutter/material.dart';

import 'pulse/backend.dart';
import 'pulse/model.dart';
import 'widgets/instant_menu.dart';
import 'widgets/tiles.dart';

void main() {
  final mock = Platform.environment['PAVU_MOCK'] == '1';
  final backend = mock ? MockBackend() : PactlBackend();
  backend.start();
  runApp(VolumeControlApp(backend: backend));
}

/// Page routes appear instantly.
class _NoTransitions extends PageTransitionsBuilder {
  const _NoTransitions();
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      child;
}

/// Hover/press feedback via state colors with zero duration, instead of fading ink.
ButtonStyle _instantButtons(ColorScheme s) => ButtonStyle(
      animationDuration: Duration.zero,
      splashFactory: NoSplash.splashFactory,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      backgroundColor: WidgetStateProperty.resolveWith((st) {
        if (st.contains(WidgetState.selected)) return s.secondaryContainer;
        if (st.contains(WidgetState.pressed)) return s.onSurface.withValues(alpha: 0.12);
        if (st.contains(WidgetState.hovered) || st.contains(WidgetState.focused)) {
          return s.onSurface.withValues(alpha: 0.07);
        }
        return null;
      }),
    );

ThemeData _theme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3584E4), brightness: b);
  final buttons = _instantButtons(scheme);
  return ThemeData(
    colorScheme: scheme,
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: scheme.onSurface.withValues(alpha: 0.05),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.linux: _NoTransitions(),
      TargetPlatform.android: _NoTransitions(),
      TargetPlatform.macOS: _NoTransitions(),
      TargetPlatform.windows: _NoTransitions(),
      TargetPlatform.iOS: _NoTransitions(),
      TargetPlatform.fuchsia: _NoTransitions(),
    }),
    menuButtonTheme: MenuButtonThemeData(style: buttons),
    textButtonTheme: TextButtonThemeData(style: buttons),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttons),
    iconButtonTheme: IconButtonThemeData(style: buttons),
    menuTheme: const MenuThemeData(style: MenuStyle(visualDensity: VisualDensity.compact)),
    popupMenuTheme: const PopupMenuThemeData(),
    tabBarTheme: TabBarThemeData(
      splashFactory: NoSplash.splashFactory,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      dividerColor: scheme.outlineVariant,
      tabAlignment: TabAlignment.start,
      labelStyle: const TextStyle(fontWeight: FontWeight.w600),
    ),
    sliderTheme: SliderThemeData(overlayShape: SliderComponentShape.noOverlay, trackHeight: 4),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 600), exitDuration: Duration.zero),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
  );
}

class VolumeControlApp extends StatelessWidget {
  const VolumeControlApp({super.key, required this.backend});
  final PulseBackend backend;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Volume Control',
      debugShowCheckedModeBanner: false,
      themeAnimationDuration: Duration.zero,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: HomePage(backend: backend),
    );
  }
}

enum StreamFilter { all, applications, virtual }

enum DeviceFilter { all, allExceptMonitors, hardware, virtual, monitors }

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.backend});
  final PulseBackend backend;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: 5, vsync: this, animationDuration: Duration.zero)..addListener(() => setState(() {}));

  var _playbackFilter = StreamFilter.applications;
  var _recordingFilter = StreamFilter.applications;
  var _outputFilter = DeviceFilter.all;
  var _inputFilter = DeviceFilter.allExceptMonitors;

  @override
  void dispose() {
    _tabs.dispose();
    widget.backend.dispose();
    super.dispose();
  }

  bool _streamOk(PaStream s, StreamFilter f) => switch (f) {
        StreamFilter.all => true,
        StreamFilter.applications => !s.isVirtual,
        StreamFilter.virtual => s.isVirtual,
      };

  bool _deviceOk(PaDevice d, DeviceFilter f) => switch (f) {
        DeviceFilter.all => true,
        DeviceFilter.allExceptMonitors => !d.isMonitor,
        DeviceFilter.hardware => d.hardware && !d.isMonitor,
        DeviceFilter.virtual => !d.hardware && !d.isMonitor,
        DeviceFilter.monitors => d.isMonitor,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ValueListenableBuilder<PaState>(
        valueListenable: widget.backend.state,
        builder: (context, st, _) {
          return Column(
            children: [
              TabBar(
                controller: _tabs,
                isScrollable: true,
                tabs: const [
                  Tab(text: 'Playback', height: 40),
                  Tab(text: 'Recording', height: 40),
                  Tab(text: 'Output Devices', height: 40),
                  Tab(text: 'Input Devices', height: 40),
                  Tab(text: 'Configuration', height: 40),
                ],
              ),
              Expanded(child: _body(st)),
              if (_tabs.index < 4) ...[const Divider(), _footer()],
            ],
          );
        },
      ),
    );
  }

  Widget _body(PaState st) {
    if (!st.loaded) return const Center(child: Text('Establishing connection to PulseAudio. Please wait...'));
    if (st.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(st.error!, textAlign: TextAlign.center),
        ),
      );
    }
    final be = widget.backend;
    switch (_tabs.index) {
      case 0:
        final items = st.sinkInputs.where((s) => _streamOk(s, _playbackFilter)).toList();
        return _list(items.length, 'No application is currently playing audio.',
            (i) => StreamTile(key: ValueKey('si${items[i].index}'), stream: items[i], devices: st.sinks, backend: be));
      case 1:
        final items = st.sourceOutputs.where((s) => _streamOk(s, _recordingFilter)).toList();
        return _list(items.length, 'No application is currently recording audio.',
            (i) => StreamTile(key: ValueKey('so${items[i].index}'), stream: items[i], devices: st.sources, backend: be));
      case 2:
        final items = st.sinks.where((d) => _deviceOk(d, _outputFilter)).toList();
        return _list(
            items.length,
            'No output devices available',
            (i) => DeviceTile(
                key: ValueKey('sink${items[i].index}'),
                device: items[i],
                isDefault: items[i].name == st.defaultSink,
                card: st.cardFor(items[i]),
                backend: be));
      case 3:
        final items = st.sources.where((d) => _deviceOk(d, _inputFilter)).toList();
        return _list(
            items.length,
            'No input devices available',
            (i) => DeviceTile(
                key: ValueKey('source${items[i].index}'),
                device: items[i],
                isDefault: items[i].name == st.defaultSource,
                card: st.cardFor(items[i]),
                backend: be));
      default:
        return _list(st.cards.length, 'No cards available for configuration',
            (i) => CardTile(key: ValueKey('card${st.cards[i].index}'), card: st.cards[i], backend: be));
    }
  }

  Widget _list(int n, String empty, Widget Function(int) item) {
    if (n == 0) {
      return Center(
        child: Text(empty, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
    }
    return ListView.separated(
      // Keyed per tab so scroll position doesn't leak between tabs.
      key: PageStorageKey('tab${_tabs.index}'),
      itemCount: n,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (_, i) => item(i),
    );
  }

  Widget _footer() {
    Widget picker<T>(T value, List<MenuEntry<T>> entries, ValueChanged<T> set) => InstantDropdown<T>(
          value: value,
          entries: entries,
          onSelected: (v) => setState(() => set(v)),
        );
    final Widget dd = switch (_tabs.index) {
      0 => picker(_playbackFilter, const [
          MenuEntry(StreamFilter.all, 'All Streams'),
          MenuEntry(StreamFilter.applications, 'Applications'),
          MenuEntry(StreamFilter.virtual, 'Virtual Streams'),
        ], (v) => _playbackFilter = v),
      1 => picker(_recordingFilter, const [
          MenuEntry(StreamFilter.all, 'All Streams'),
          MenuEntry(StreamFilter.applications, 'Applications'),
          MenuEntry(StreamFilter.virtual, 'Virtual Streams'),
        ], (v) => _recordingFilter = v),
      2 => picker(_outputFilter, const [
          MenuEntry(DeviceFilter.all, 'All Output Devices'),
          MenuEntry(DeviceFilter.hardware, 'Hardware Output Devices'),
          MenuEntry(DeviceFilter.virtual, 'Virtual Output Devices'),
        ], (v) => _outputFilter = v),
      _ => picker(_inputFilter, const [
          MenuEntry(DeviceFilter.all, 'All Input Devices'),
          MenuEntry(DeviceFilter.allExceptMonitors, 'All Except Monitors'),
          MenuEntry(DeviceFilter.hardware, 'Hardware Input Devices'),
          MenuEntry(DeviceFilter.virtual, 'Virtual Input Devices'),
          MenuEntry(DeviceFilter.monitors, 'Monitors'),
        ], (v) => _inputFilter = v),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [const Text('Show:'), const SizedBox(width: 8), dd],
      ),
    );
  }
}
