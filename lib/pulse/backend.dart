import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'model.dart';

/// Our own meter streams carry this so they can be hidden from the Recording tab.
const meterAppId = 'dev.v.pavucontrol_flutter.meter';

abstract class PulseBackend {
  final ValueNotifier<PaState> state = ValueNotifier(const PaState());

  Future<void> start();
  void dispose();

  void setVolume(PaDevice d, List<int> values);
  void setMute(PaDevice d, bool mute);
  void setDefault(PaDevice d);
  void setPort(PaDevice d, String port);
  void setLatencyOffset(String card, String port, int usec);

  void setStreamVolume(PaStream s, List<int> values);
  void setStreamMute(PaStream s, bool mute);
  void moveStream(PaStream s, PaDevice target);
  void killStream(PaStream s);

  void setCardProfile(PaCard c, String profile);

  /// Live peak level 0..1 for a device or (when [streamIndex] is set) a playback stream.
  Stream<double> meter(String source, {int? streamIndex});
}

/// Starts a long-running helper tied to our lifetime: when our stdin pipe closes
/// (we exit, crash, or call [stopTied]) the helper is killed, so no orphans are left.
Future<Process> startTied(String cmd, List<String> args) => Process.start('sh', [
      '-c',
      // Background jobs get /dev/null as stdin, so hand the watcher our stdin via fd 3.
      r'exec 3<&0; "$@" 3<&- & p=$!; (cat <&3 >/dev/null; kill $p 2>/dev/null) & exec 3<&-; wait $p',
      'sh',
      cmd,
      ...args,
    ]);

void stopTied(Process? p) {
  if (p == null) return;
  p.stdin.close().catchError((_) {});
}

/// Talks to PulseAudio / pipewire-pulse via the `pactl` and `parec` CLIs.
class PactlBackend extends PulseBackend {
  Process? _subscriber;
  Timer? _debounce;
  bool _refreshing = false;
  bool _dirty = false;
  bool _disposed = false;

  // One in-flight pactl per key; newest pending args win (keeps slider drags smooth).
  final Map<String, List<String>> _pending = {};
  final Set<String> _inFlight = {};

  @override
  Future<void> start() async {
    await _refresh();
    if (state.value.error != null) {
      // Server not up yet (or restarting): keep trying, like pavucontrol does.
      Future.delayed(const Duration(seconds: 2), () {
        if (!_disposed) start();
      });
      return;
    }
    try {
      _subscriber = await startTied('pactl', ['subscribe']);
      _subscriber!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.startsWith('Event')) _scheduleRefresh();
      });
      _subscriber!.exitCode.then((_) {
        stopTied(_subscriber);
        if (!_disposed) {
          // Server restarted or went away: retry.
          Future.delayed(const Duration(seconds: 2), () {
            if (!_disposed) start();
          });
        }
      });
    } catch (_) {}
  }

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 40), _refresh);
  }

  Future<dynamic> _json(List<String> args) async {
    final r = await Process.run('pactl', ['-f', 'json', ...args], stdoutEncoding: utf8);
    if (r.exitCode != 0) {
      throw '${r.stderr}'.trim().isEmpty ? 'pactl ${args.join(' ')} failed' : '${r.stderr}'.trim();
    }
    return jsonDecode(r.stdout as String);
  }

  Future<void> _refresh() async {
    if (_refreshing) {
      _dirty = true;
      return;
    }
    _refreshing = true;
    try {
      final res = await Future.wait([
        _json(['list', 'sinks']),
        _json(['list', 'sources']),
        _json(['list', 'sink-inputs']),
        _json(['list', 'source-outputs']),
        _json(['list', 'cards']),
        _json(['info']),
      ]);
      List<Map> maps(dynamic l) => l is List ? l.whereType<Map>().toList() : const [];
      final info = res[5] is Map ? res[5] as Map : const {};
      state.value = PaState(
        sinks: [for (final j in maps(res[0])) PaDevice.parse(DeviceKind.sink, j)],
        sources: [for (final j in maps(res[1])) PaDevice.parse(DeviceKind.source, j)],
        sinkInputs: [for (final j in maps(res[2])) PaStream.parse(DeviceKind.sink, j)],
        sourceOutputs: [
          for (final j in maps(res[3]))
            if (asProps(j['properties'])['application.id'] != meterAppId) PaStream.parse(DeviceKind.source, j)
        ],
        cards: [for (final j in maps(res[4])) PaCard.parse(j)],
        defaultSink: asName(info['default_sink_name']),
        defaultSource: asName(info['default_source_name']),
        loaded: true,
      );
    } on ProcessException {
      state.value = const PaState(
          loaded: true, error: '`pactl` was not found. Install pulseaudio-utils / libpulse (pactl ≥ 16).');
    } on FormatException {
      state.value = const PaState(
          loaded: true, error: 'pactl did not return JSON. pactl ≥ 16 (with -f json) is required.');
    } catch (e) {
      state.value = PaState(loaded: true, error: 'Connection failure: $e');
    } finally {
      _refreshing = false;
      if (_dirty) {
        _dirty = false;
        _scheduleRefresh();
      }
    }
  }

  void _run(String key, List<String> args) {
    _pending[key] = args;
    if (_inFlight.contains(key)) return;
    _drain(key);
  }

  Future<void> _drain(String key) async {
    _inFlight.add(key);
    while (_pending.containsKey(key)) {
      final args = _pending.remove(key)!;
      try {
        await Process.run('pactl', args);
      } catch (_) {}
    }
    _inFlight.remove(key);
  }

  String _k(DeviceKind k) => k == DeviceKind.sink ? 'sink' : 'source';

  @override
  void setVolume(PaDevice d, List<int> v) =>
      _run('vol-${_k(d.kind)}-${d.index}', ['set-${_k(d.kind)}-volume', d.name, ...v.map((e) => '$e')]);

  @override
  void setMute(PaDevice d, bool mute) =>
      _run('mute-${_k(d.kind)}-${d.index}', ['set-${_k(d.kind)}-mute', d.name, mute ? '1' : '0']);

  @override
  void setDefault(PaDevice d) => _run('default-${_k(d.kind)}', ['set-default-${_k(d.kind)}', d.name]);

  @override
  void setPort(PaDevice d, String port) =>
      _run('port-${_k(d.kind)}-${d.index}', ['set-${_k(d.kind)}-port', d.name, port]);

  @override
  void setLatencyOffset(String card, String port, int usec) =>
      _run('lat-$card-$port', ['set-port-latency-offset', card, port, '$usec']);

  String _s(DeviceKind k) => k == DeviceKind.sink ? 'sink-input' : 'source-output';

  @override
  void setStreamVolume(PaStream s, List<int> v) =>
      _run('vol-${_s(s.kind)}-${s.index}', ['set-${_s(s.kind)}-volume', '${s.index}', ...v.map((e) => '$e')]);

  @override
  void setStreamMute(PaStream s, bool mute) =>
      _run('mute-${_s(s.kind)}-${s.index}', ['set-${_s(s.kind)}-mute', '${s.index}', mute ? '1' : '0']);

  @override
  void moveStream(PaStream s, PaDevice target) =>
      _run('move-${_s(s.kind)}-${s.index}', ['move-${_s(s.kind)}', '${s.index}', target.name]);

  @override
  void killStream(PaStream s) => _run('kill-${_s(s.kind)}-${s.index}', ['kill-${_s(s.kind)}', '${s.index}']);

  @override
  void setCardProfile(PaCard c, String profile) =>
      _run('profile-${c.index}', ['set-card-profile', c.name, profile]);

  @override
  Stream<double> meter(String source, {int? streamIndex}) {
    late StreamController<double> ctrl;
    Process? proc;
    ctrl = StreamController<double>(
      onListen: () async {
        try {
          proc = await startTied('parec', [
            '--raw',
            '--format=float32le',
            '--channels=1',
            '--rate=8000',
            '--latency-msec=40',
            '--client-name=pavucontrol-flutter',
            '--property=application.id=$meterAppId',
            '--property=media.role=abstract',
            '--property=node.passive=true',
            '-d',
            source,
            if (streamIndex != null) '--monitor-stream=$streamIndex',
          ]);
          if (ctrl.isClosed) {
            stopTied(proc);
            return;
          }
          final carry = BytesBuilder(copy: false);
          proc!.stdout.listen((chunk) {
            carry.add(chunk);
            final bytes = carry.takeBytes();
            final usable = bytes.length - bytes.length % 4;
            if (usable < bytes.length) carry.add(bytes.sublist(usable));
            if (usable == 0) return;
            final bd = ByteData.sublistView(Uint8List.fromList(bytes.sublist(0, usable)));
            var peak = 0.0;
            for (var i = 0; i < usable; i += 4) {
              final s = bd.getFloat32(i, Endian.little).abs();
              if (s > peak) peak = s;
            }
            if (!ctrl.isClosed) ctrl.add(peak.clamp(0.0, 1.0));
          });
          proc!.stderr.drain<void>();
        } catch (_) {
          // parec missing: meter just stays empty.
        }
      },
      onCancel: () {
        stopTied(proc);
        ctrl.close();
      },
    );
    return ctrl.stream;
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    stopTied(_subscriber);
  }
}

/// In-memory fake for UI work and screenshots (run with PAVU_MOCK=1).
class MockBackend extends PulseBackend {
  final _rng = math.Random(7);

  static const _st = ['front-left', 'front-right'];
  static ChannelVolumes _v(double l, [double? r]) =>
      ChannelVolumes(_st, [(l * volumeNorm).round(), ((r ?? l) * volumeNorm).round()]);

  @override
  Future<void> start() async {
    PaDevice dev(DeviceKind k, int i, String name, String desc, ChannelVolumes v,
            {bool hw = true, String? monOf, List<PaPort> ports = const [], String? port, int? card}) =>
        PaDevice(
          kind: k,
          index: i,
          name: name,
          description: desc,
          mute: false,
          volume: v,
          baseVolume: volumeNorm,
          decibel: true,
          hardware: hw,
          monitorSource: k == DeviceKind.sink ? '$name.monitor' : null,
          monitorOfSink: monOf,
          ports: ports,
          activePort: port,
          card: card,
          props: const {},
        );
    final speakers = [
      const PaPort('analog-output-speaker', 'Speakers', true, 100),
      const PaPort('analog-output-headphones', 'Headphones', false, 90),
    ];
    state.value = PaState(
      loaded: true,
      defaultSink: 'alsa_output.pci-0000_00_1f.3.analog-stereo',
      defaultSource: 'alsa_input.usb-Blue_Yeti-00.analog-stereo',
      sinks: [
        dev(DeviceKind.sink, 0, 'alsa_output.pci-0000_00_1f.3.analog-stereo', 'Built-in Audio Analog Stereo',
            _v(0.74), ports: speakers, port: 'analog-output-speaker', card: 0),
        dev(DeviceKind.sink, 1, 'alsa_output.pci-0000_01_00.1.hdmi-stereo', 'HDA NVidia Digital Stereo (HDMI)',
            _v(1.0), ports: [const PaPort('hdmi-output-0', 'HDMI / DisplayPort', true, 59)],
            port: 'hdmi-output-0', card: 1),
        dev(DeviceKind.sink, 2, 'effect_input.eq', 'Equalizer Sink', _v(0.9), hw: false),
      ],
      sources: [
        dev(DeviceKind.source, 0, 'alsa_input.usb-Blue_Yeti-00.analog-stereo', 'Yeti Stereo Microphone',
            _v(0.62), ports: [const PaPort('analog-input-mic', 'Microphone', true, 85)],
            port: 'analog-input-mic', card: 2),
        dev(DeviceKind.source, 1, 'alsa_output.pci-0000_00_1f.3.analog-stereo.monitor',
            'Monitor of Built-in Audio Analog Stereo', _v(1.0),
            monOf: 'alsa_output.pci-0000_00_1f.3.analog-stereo'),
      ],
      sinkInputs: [
        PaStream(
            kind: DeviceKind.sink, index: 40, client: 12, device: 0, mute: false, corked: false,
            volume: _v(0.85), props: const {'application.name': 'Firefox', 'media.name': 'Lofi beats to code to'}),
        PaStream(
            kind: DeviceKind.sink, index: 41, client: 13, device: 0, mute: true, corked: false,
            volume: _v(1.0, 0.7), props: const {'application.name': 'Spotify', 'media.name': 'Spotify'}),
        PaStream(
            kind: DeviceKind.sink, index: 42, client: 14, device: 1, mute: false, corked: false,
            volume: _v(0.6), props: const {'application.name': 'Minecraft', 'media.name': 'game audio'}),
      ],
      sourceOutputs: [
        PaStream(
            kind: DeviceKind.source, index: 50, client: 15, device: 0, mute: false, corked: false,
            volume: _v(1.0), props: const {'application.name': 'OBS Studio', 'media.name': 'Mic/Aux'}),
      ],
      cards: [
        PaCard(0, 'alsa_card.pci-0000_00_1f.3', 'Built-in Audio', const [
          PaProfile('output:analog-stereo+input:analog-stereo', 'Analog Stereo Duplex', true, 6565),
          PaProfile('output:analog-stereo', 'Analog Stereo Output', true, 6500),
          PaProfile('output:analog-surround-51', 'Analog Surround 5.1 Output', false, 1300),
          PaProfile('off', 'Off', true, 0),
        ], 'output:analog-stereo', const [], const {}),
        PaCard(1, 'alsa_card.pci-0000_01_00.1', 'HDA NVidia', const [
          PaProfile('output:hdmi-stereo', 'Digital Stereo (HDMI) Output', true, 5900),
          PaProfile('off', 'Off', true, 0),
        ], 'output:hdmi-stereo', const [], const {}),
        PaCard(2, 'alsa_card.usb-Blue_Yeti-00', 'Yeti Stereo Microphone', const [
          PaProfile('input:analog-stereo', 'Analog Stereo Input', true, 65),
          PaProfile('off', 'Off', true, 0),
        ], 'input:analog-stereo', const [], const {}),
      ],
    );
  }

  PaState get _s => state.value;

  void _emit({
    List<PaDevice>? sinks,
    List<PaDevice>? sources,
    List<PaStream>? sinkInputs,
    List<PaStream>? sourceOutputs,
    List<PaCard>? cards,
    String? defaultSink,
    String? defaultSource,
  }) {
    state.value = PaState(
      loaded: true,
      sinks: sinks ?? _s.sinks,
      sources: sources ?? _s.sources,
      sinkInputs: sinkInputs ?? _s.sinkInputs,
      sourceOutputs: sourceOutputs ?? _s.sourceOutputs,
      cards: cards ?? _s.cards,
      defaultSink: defaultSink ?? _s.defaultSink,
      defaultSource: defaultSource ?? _s.defaultSource,
    );
  }

  PaDevice _cp(PaDevice d, {bool? mute, ChannelVolumes? volume, String? port}) => PaDevice(
        kind: d.kind, index: d.index, name: d.name, description: d.description, mute: mute ?? d.mute,
        volume: volume ?? d.volume, baseVolume: d.baseVolume, decibel: d.decibel, hardware: d.hardware,
        monitorSource: d.monitorSource, monitorOfSink: d.monitorOfSink, ports: d.ports,
        activePort: port ?? d.activePort, card: d.card, props: d.props);

  PaStream _cs(PaStream s, {bool? mute, ChannelVolumes? volume, int? device}) => PaStream(
      kind: s.kind, index: s.index, client: s.client, device: device ?? s.device, mute: mute ?? s.mute,
      corked: s.corked, volume: volume ?? s.volume, props: s.props);

  void _dev(PaDevice d, PaDevice Function(PaDevice) f) {
    List<PaDevice> map(List<PaDevice> l) => [for (final x in l) x.index == d.index ? f(x) : x];
    d.kind == DeviceKind.sink ? _emit(sinks: map(_s.sinks)) : _emit(sources: map(_s.sources));
  }

  void _str(PaStream s, PaStream Function(PaStream) f) {
    List<PaStream> map(List<PaStream> l) => [for (final x in l) x.index == s.index ? f(x) : x];
    s.kind == DeviceKind.sink
        ? _emit(sinkInputs: map(_s.sinkInputs))
        : _emit(sourceOutputs: map(_s.sourceOutputs));
  }

  @override
  void setVolume(PaDevice d, List<int> v) => _dev(d, (x) => _cp(x, volume: ChannelVolumes(x.volume.channels, v)));
  @override
  void setMute(PaDevice d, bool mute) => _dev(d, (x) => _cp(x, mute: mute));
  @override
  void setDefault(PaDevice d) =>
      d.kind == DeviceKind.sink ? _emit(defaultSink: d.name) : _emit(defaultSource: d.name);
  @override
  void setPort(PaDevice d, String port) => _dev(d, (x) => _cp(x, port: port));
  @override
  void setLatencyOffset(String card, String port, int usec) {}
  @override
  void setStreamVolume(PaStream s, List<int> v) =>
      _str(s, (x) => _cs(x, volume: ChannelVolumes(x.volume.channels, v)));
  @override
  void setStreamMute(PaStream s, bool mute) => _str(s, (x) => _cs(x, mute: mute));
  @override
  void moveStream(PaStream s, PaDevice target) => _str(s, (x) => _cs(x, device: target.index));
  @override
  void killStream(PaStream s) => s.kind == DeviceKind.sink
      ? _emit(sinkInputs: _s.sinkInputs.where((x) => x.index != s.index).toList())
      : _emit(sourceOutputs: _s.sourceOutputs.where((x) => x.index != s.index).toList());
  @override
  void setCardProfile(PaCard c, String profile) => _emit(cards: [
        for (final x in _s.cards)
          x.index == c.index ? PaCard(x.index, x.name, x.description, x.profiles, profile, x.ports, x.props) : x
      ]);

  @override
  Stream<double> meter(String source, {int? streamIndex}) {
    final phase = _rng.nextDouble() * 6;
    final level = 0.3 + _rng.nextDouble() * 0.5;
    return Stream.periodic(const Duration(milliseconds: 40), (i) {
      final v = level * (0.6 + 0.4 * math.sin(phase + i / 5)) + _rng.nextDouble() * 0.08;
      return v.clamp(0.0, 1.0);
    });
  }

  @override
  void dispose() {}
}
