import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'libpulse.dart';
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

typedef _Issue = Pointer<Void> Function(Arena a, Pointer<NativeFunction<pa_context_success_cb>> cb, Pointer<Void> ud);

class _Meter {
  final String source;
  final int? streamIndex;
  final StreamController<double> ctrl;
  Pointer<Void> stream = nullptr;
  _Meter(this.source, this.streamIndex, this.ctrl);
}

class _Snapshot {
  List<PaDevice> sinks = const [], sources = const [];
  List<PaStream> sinkInputs = const [], sourceOutputs = const [];
  List<PaCard> cards = const [];
  String? defaultSink, defaultSource;
  final sinkAcc = <PaDevice>[], sourceAcc = <PaDevice>[];
  final sinkInputAcc = <PaStream>[], sourceOutputAcc = <PaStream>[];
  final cardAcc = <PaCard>[];
  int pending = 6;
}

/// Talks to PulseAudio / pipewire-pulse directly through libpulse (dart:ffi).
///
/// Runs a plain `pa_mainloop` on the UI isolate, iterated without blocking from a timer, so
/// every libpulse callback runs synchronously on this thread and can read the info structs
/// while they are still valid.
class LibpulseBackend extends PulseBackend {
  LibPulse? _pa;
  Pointer<Void> _ml = nullptr;
  Pointer<Void> _ctx = nullptr;
  bool _ready = false;
  bool _disposed = false;
  Timer? _tick;
  Timer? _debounce;
  Timer? _retry;

  bool _refreshing = false;
  bool _dirty = false;
  int _gen = 0;
  _Snapshot? _snap;

  // One in-flight operation per key; newest pending request wins (keeps slider drags smooth).
  final Map<String, _Issue> _pending = {};
  final Set<String> _inFlight = {};
  final Map<int, String> _opKeys = {};
  int _nextOp = 1;

  final Map<int, _Meter> _meters = {};
  int _nextMeter = 1;

  late final _stateCb = NativeCallable<pa_context_notify_cb>.isolateLocal(_onState);
  late final _subscribeCb = NativeCallable<pa_context_subscribe_cb>.isolateLocal(_onEvent);
  late final _successCb = NativeCallable<pa_context_success_cb>.isolateLocal(_onSuccess);
  late final _sinkCb = NativeCallable<pa_device_info_cb>.isolateLocal(_onSink);
  late final _sourceCb = NativeCallable<pa_device_info_cb>.isolateLocal(_onSource);
  late final _sinkInputCb = NativeCallable<pa_sink_input_info_cb>.isolateLocal(_onSinkInput);
  late final _sourceOutputCb = NativeCallable<pa_source_output_info_cb>.isolateLocal(_onSourceOutput);
  late final _cardCb = NativeCallable<pa_card_info_cb>.isolateLocal(_onCard);
  late final _serverCb = NativeCallable<pa_server_info_cb>.isolateLocal(_onServer);
  late final _readCb = NativeCallable<pa_stream_request_cb>.isolateLocal(_onRead);

  @override
  Future<void> start() async {
    if (_disposed) return;
    if (_pa == null) {
      try {
        _pa = LibPulse(openLibpulse());
      } catch (_) {
        state.value = const PaState(
          loaded: true,
          error: 'libpulse was not found. Install your distribution\'s libpulse (libpulse0 / pulseaudio-libs).',
        );
        return;
      }
      _ml = _pa!.mainloop_new();
    }
    _connect();
  }

  void _connect() {
    final pa = _pa!;
    _ctx = using((a) {
      final props = pa.proplist_new();
      void set(String k, String v) =>
          pa.proplist_sets(props, k.toNativeUtf8(allocator: a), v.toNativeUtf8(allocator: a));
      set('application.id', 'dev.v.pavucontrol_flutter');
      set('application.icon_name', 'multimedia-volume-control');
      final ctx = pa.context_new_with_proplist(
        pa.mainloop_get_api(_ml),
        'pavucontrol-flutter'.toNativeUtf8(allocator: a),
        props,
      );
      pa.proplist_free(props);
      return ctx;
    });
    pa.context_set_state_callback(_ctx, _stateCb.nativeFunction, nullptr);
    if (pa.context_connect(_ctx, nullptr, 0, nullptr) < 0) {
      _failed();
      return;
    }
    _kick();
  }

  void _onState(Pointer<Void> c, Pointer<Void> _) {
    if (c != _ctx) return;
    final s = _pa!.context_get_state(c);
    if (s == paContextReady) {
      _ready = true;
      _pa!.context_set_subscribe_callback(_ctx, _subscribeCb.nativeFunction, nullptr);
      _unref(_pa!.context_subscribe(_ctx, paSubscriptionMaskAll, nullptr, nullptr));
      for (final m in _meters.values) {
        _openMeter(m);
      }
      _refresh();
    } else if (s == paContextFailed || s == paContextTerminated) {
      // Tear down outside of libpulse's dispatch.
      Timer.run(_failed);
    }
  }

  /// Connection failed or the server went away: report it and retry, like pavucontrol does.
  void _failed() {
    if (_ctx == nullptr) return;
    final pa = _pa!;
    final err = pa.strerror(pa.context_errno(_ctx)).toDartString();
    _teardownContext();
    state.value = PaState(loaded: true, error: 'Connection failure: $err');
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), () {
      if (!_disposed) _connect();
    });
  }

  void _teardownContext() {
    final pa = _pa!;
    for (final m in _meters.values) {
      _closeMeterStream(m);
    }
    pa.context_set_state_callback(_ctx, nullptr, nullptr);
    pa.context_set_subscribe_callback(_ctx, nullptr, nullptr);
    pa.context_disconnect(_ctx);
    pa.context_unref(_ctx);
    _ctx = nullptr;
    _ready = false;
    _refreshing = false;
    _dirty = false;
    _snap = null;
    _pending.clear();
    _inFlight.clear();
    _opKeys.clear();
  }

  // --- main loop -------------------------------------------------------------------------

  bool get _busy => !_ready || _meters.isNotEmpty || _inFlight.isNotEmpty || _refreshing;

  void _iterate() {
    _tick = null;
    if (_disposed || _ctx == nullptr) return;
    for (var i = 0; i < 64; i++) {
      if (_pa!.mainloop_iterate(_ml, 0, nullptr) <= 0) break;
    }
    _tick ??= Timer(Duration(milliseconds: _busy ? 16 : 100), _iterate);
  }

  /// Flush requests to the server now instead of on the next tick.
  void _kick() {
    _tick?.cancel();
    _tick = Timer(Duration.zero, _iterate);
  }

  void _unref(Pointer<Void> op) {
    if (op != nullptr) _pa!.operation_unref(op);
  }

  // --- state ---------------------------------------------------------------------------

  void _onEvent(Pointer<Void> c, int t, int idx, Pointer<Void> _) => _scheduleRefresh();

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 40), _refresh);
  }

  void _refresh() {
    if (!_ready || _disposed) return;
    if (_refreshing) {
      _dirty = true;
      return;
    }
    _refreshing = true;
    _snap = _Snapshot();
    final pa = _pa!;
    final ud = Pointer<Void>.fromAddress(++_gen);
    final ops = [
      pa.get_sink_info_list(_ctx, _sinkCb.nativeFunction, ud),
      pa.get_source_info_list(_ctx, _sourceCb.nativeFunction, ud),
      pa.get_sink_input_info_list(_ctx, _sinkInputCb.nativeFunction, ud),
      pa.get_source_output_info_list(_ctx, _sourceOutputCb.nativeFunction, ud),
      pa.get_card_info_list(_ctx, _cardCb.nativeFunction, ud),
      pa.get_server_info(_ctx, _serverCb.nativeFunction, ud),
    ];
    for (final op in ops) {
      if (op == nullptr) {
        _snap!.pending--;
      } else {
        pa.operation_unref(op);
      }
    }
    _kick();
    if (_snap!.pending == 0) _finishRefresh();
  }

  _Snapshot? _snapFor(Pointer<Void> ud) => ud.address == _gen ? _snap : null;

  void _partDone(_Snapshot s) {
    if (--s.pending == 0) _finishRefresh();
  }

  void _finishRefresh() {
    final s = _snap!;
    _snap = null;
    state.value = PaState(
      sinks: s.sinks,
      sources: s.sources,
      sinkInputs: s.sinkInputs,
      sourceOutputs: s.sourceOutputs,
      cards: s.cards,
      defaultSink: s.defaultSink,
      defaultSource: s.defaultSource,
      loaded: true,
    );
    _refreshing = false;
    if (_dirty) {
      _dirty = false;
      _scheduleRefresh();
    }
  }

  void _onSink(Pointer<Void> c, Pointer<pa_device_info> i, int eol, Pointer<Void> ud) {
    final s = _snapFor(ud);
    if (s == null) return;
    if (eol != 0) {
      s.sinks = List.of(s.sinkAcc);
      return _partDone(s);
    }
    s.sinkAcc.add(_device(DeviceKind.sink, i.ref));
  }

  void _onSource(Pointer<Void> c, Pointer<pa_device_info> i, int eol, Pointer<Void> ud) {
    final s = _snapFor(ud);
    if (s == null) return;
    if (eol != 0) {
      s.sources = List.of(s.sourceAcc);
      return _partDone(s);
    }
    s.sourceAcc.add(_device(DeviceKind.source, i.ref));
  }

  void _onSinkInput(Pointer<Void> c, Pointer<pa_sink_input_info> i, int eol, Pointer<Void> ud) {
    final s = _snapFor(ud);
    if (s == null) return;
    if (eol != 0) {
      s.sinkInputs = List.of(s.sinkInputAcc);
      return _partDone(s);
    }
    final r = i.ref;
    s.sinkInputAcc.add(
      PaStream(
        kind: DeviceKind.sink,
        index: r.index,
        client: r.client == paInvalidIndex ? null : r.client,
        device: r.sink == paInvalidIndex ? -1 : r.sink,
        mute: r.mute != 0,
        corked: r.corked != 0,
        volume: r.has_volume != 0 ? _volume(r.volume, r.channel_map) : ChannelVolumes.empty,
        props: _props(r.proplist),
      ),
    );
  }

  void _onSourceOutput(Pointer<Void> c, Pointer<pa_source_output_info> i, int eol, Pointer<Void> ud) {
    final s = _snapFor(ud);
    if (s == null) return;
    if (eol != 0) {
      s.sourceOutputs = List.of(s.sourceOutputAcc);
      return _partDone(s);
    }
    final r = i.ref;
    final props = _props(r.proplist);
    if (props['application.id'] == meterAppId) return;
    s.sourceOutputAcc.add(
      PaStream(
        kind: DeviceKind.source,
        index: r.index,
        client: r.client == paInvalidIndex ? null : r.client,
        device: r.source == paInvalidIndex ? -1 : r.source,
        mute: r.mute != 0,
        corked: r.corked != 0,
        volume: r.has_volume != 0 ? _volume(r.volume, r.channel_map) : ChannelVolumes.empty,
        props: props,
      ),
    );
  }

  void _onCard(Pointer<Void> c, Pointer<pa_card_info> i, int eol, Pointer<Void> ud) {
    final s = _snapFor(ud);
    if (s == null) return;
    if (eol != 0) {
      s.cards = List.of(s.cardAcc);
      return _partDone(s);
    }
    final r = i.ref;
    final props = _props(r.proplist);
    final profiles = <PaProfile>[
      if (r.profiles2 != nullptr)
        for (var k = 0; k < r.n_profiles; k++)
          if (r.profiles2[k] != nullptr) _profile(r.profiles2[k].ref),
    ]..sort((a, b) => b.priority.compareTo(a.priority));
    final ports = <PaPort>[
      for (var k = 0; k < r.n_ports; k++)
        if (r.ports[k] != nullptr)
          PaPort(
            _str(r.ports[k].ref.name) ?? '',
            _str(r.ports[k].ref.description) ?? _str(r.ports[k].ref.name) ?? '',
            r.ports[k].ref.available != paPortAvailableNo,
            r.ports[k].ref.priority,
            r.ports[k].ref.latency_offset,
          ),
    ];
    final name = _str(r.name) ?? '';
    s.cardAcc.add(
      PaCard(
        r.index,
        name,
        props['device.description'] ?? name,
        profiles,
        r.active_profile2 == nullptr ? null : _str(r.active_profile2.ref.name),
        ports,
        props,
      ),
    );
  }

  void _onServer(Pointer<Void> c, Pointer<pa_server_info> i, Pointer<Void> ud) {
    final s = _snapFor(ud);
    if (s == null) return;
    if (i != nullptr) {
      s.defaultSink = _str(i.ref.default_sink_name);
      s.defaultSource = _str(i.ref.default_source_name);
    }
    _partDone(s);
  }

  String? _str(Pointer<Utf8> p) => p == nullptr ? null : asName(p.toDartString());

  Map<String, String> _props(Pointer<Void> pl) {
    if (pl == nullptr) return const {};
    final pa = _pa!;
    final out = <String, String>{};
    final it = calloc<Pointer<Void>>();
    try {
      while (true) {
        final key = pa.proplist_iterate(pl, it);
        if (key == nullptr) break;
        final v = pa.proplist_gets(pl, key);
        if (v != nullptr) out[key.toDartString()] = v.toDartString();
      }
    } finally {
      calloc.free(it);
    }
    return out;
  }

  ChannelVolumes _volume(pa_cvolume v, pa_channel_map map) {
    final n = math.min(v.channels, paChannelsMax);
    return ChannelVolumes(
      [
        for (var k = 0; k < n; k++)
          k < map.channels ? (_pa!.channel_position_to_string(map.map[k]).toDartString()) : 'aux$k',
      ],
      [for (var k = 0; k < n; k++) v.values[k]],
    );
  }

  PaProfile _profile(pa_card_profile_info2 p) =>
      PaProfile(_str(p.name) ?? '', _str(p.description) ?? _str(p.name) ?? '', p.available != 0, p.priority);

  PaDevice _device(DeviceKind kind, pa_device_info i) {
    final props = _props(i.proplist);
    final name = _str(i.name) ?? '';
    return PaDevice(
      kind: kind,
      index: i.index,
      name: name,
      description: _str(i.description) ?? name,
      mute: i.mute != 0,
      volume: _volume(i.volume, i.channel_map),
      baseVolume: i.base_volume,
      decibel: i.flags == 0 || i.flags & paDeviceDecibelVolume != 0,
      hardware: i.flags & paDeviceHardware != 0 || props.containsKey('alsa.card') || props['device.api'] == 'bluez5',
      monitorSource: kind == DeviceKind.sink ? _str(i.monitor_name) : null,
      monitorOfSink: kind == DeviceKind.source
          ? (_str(i.monitor_name) ?? (props['device.class'] == 'monitor' ? name : null))
          : null,
      ports: [
        for (var k = 0; k < i.n_ports; k++)
          if (i.ports[k] != nullptr)
            PaPort(
              _str(i.ports[k].ref.name) ?? '',
              _str(i.ports[k].ref.description) ?? _str(i.ports[k].ref.name) ?? '',
              i.ports[k].ref.available != paPortAvailableNo,
              i.ports[k].ref.priority,
            ),
      ],
      activePort: i.active_port == nullptr ? null : _str(i.active_port.ref.name),
      card: i.card == paInvalidIndex ? null : i.card,
      props: props,
    );
  }

  // --- requests ------------------------------------------------------------------------

  void _run(String key, _Issue issue) {
    _pending[key] = issue;
    if (_inFlight.contains(key)) return;
    _issue(key);
  }

  void _issue(String key) {
    final f = _pending.remove(key);
    if (f == null || !_ready) {
      _inFlight.remove(key);
      return;
    }
    final id = _nextOp++;
    _opKeys[id] = key;
    _inFlight.add(key);
    final op = using((a) => f(a, _successCb.nativeFunction, Pointer.fromAddress(id)));
    if (op == nullptr) {
      // Rejected locally (e.g. bad argument): nothing in flight, try the next one if queued.
      _opKeys.remove(id);
      _inFlight.remove(key);
      if (_pending.containsKey(key)) _issue(key);
      return;
    }
    _pa!.operation_unref(op);
    _kick();
  }

  void _onSuccess(Pointer<Void> c, int success, Pointer<Void> ud) {
    final key = _opKeys.remove(ud.address);
    if (key == null) return;
    _inFlight.remove(key);
    if (_pending.containsKey(key)) _issue(key);
  }

  Pointer<pa_cvolume> _cvolume(Arena a, List<int> values, int channels) {
    final v = values.length == 1 && channels > 1 ? List.filled(channels, values.first) : values;
    final cv = a<pa_cvolume>();
    cv.ref.channels = math.min(v.length, paChannelsMax);
    for (var k = 0; k < cv.ref.channels; k++) {
      cv.ref.values[k] = v[k].clamp(0, 0x7fffffff);
    }
    return cv;
  }

  Pointer<Utf8> Function(String) _s(Arena a) =>
      (s) => s.toNativeUtf8(allocator: a);

  String _k(DeviceKind k) => k == DeviceKind.sink ? 'sink' : 'source';
  String _sk(DeviceKind k) => k == DeviceKind.sink ? 'sink-input' : 'source-output';
  bool _isSink(DeviceKind k) => k == DeviceKind.sink;

  @override
  void setVolume(PaDevice d, List<int> v) => _run('vol-${_k(d.kind)}-${d.index}', (a, cb, ud) {
    final f = _isSink(d.kind) ? _pa!.set_sink_volume_by_name : _pa!.set_source_volume_by_name;
    return f(_ctx, _s(a)(d.name), _cvolume(a, v, d.volume.values.length), cb, ud);
  });

  @override
  void setMute(PaDevice d, bool mute) => _run('mute-${_k(d.kind)}-${d.index}', (a, cb, ud) {
    final f = _isSink(d.kind) ? _pa!.set_sink_mute_by_name : _pa!.set_source_mute_by_name;
    return f(_ctx, _s(a)(d.name), mute ? 1 : 0, cb, ud);
  });

  @override
  void setDefault(PaDevice d) => _run('default-${_k(d.kind)}', (a, cb, ud) {
    final f = _isSink(d.kind) ? _pa!.set_default_sink : _pa!.set_default_source;
    return f(_ctx, _s(a)(d.name), cb, ud);
  });

  @override
  void setPort(PaDevice d, String port) => _run('port-${_k(d.kind)}-${d.index}', (a, cb, ud) {
    final f = _isSink(d.kind) ? _pa!.set_sink_port_by_name : _pa!.set_source_port_by_name;
    return f(_ctx, _s(a)(d.name), _s(a)(port), cb, ud);
  });

  @override
  void setLatencyOffset(String card, String port, int usec) => _run(
    'lat-$card-$port',
    (a, cb, ud) => _pa!.set_port_latency_offset(_ctx, _s(a)(card), _s(a)(port), usec, cb, ud),
  );

  @override
  void setStreamVolume(PaStream s, List<int> v) => _run('vol-${_sk(s.kind)}-${s.index}', (a, cb, ud) {
    final f = _isSink(s.kind) ? _pa!.set_sink_input_volume : _pa!.set_source_output_volume;
    return f(_ctx, s.index, _cvolume(a, v, s.volume.values.length), cb, ud);
  });

  @override
  void setStreamMute(PaStream s, bool mute) => _run('mute-${_sk(s.kind)}-${s.index}', (a, cb, ud) {
    final f = _isSink(s.kind) ? _pa!.set_sink_input_mute : _pa!.set_source_output_mute;
    return f(_ctx, s.index, mute ? 1 : 0, cb, ud);
  });

  @override
  void moveStream(PaStream s, PaDevice target) => _run('move-${_sk(s.kind)}-${s.index}', (a, cb, ud) {
    final f = _isSink(s.kind) ? _pa!.move_sink_input_by_name : _pa!.move_source_output_by_name;
    return f(_ctx, s.index, _s(a)(target.name), cb, ud);
  });

  @override
  void killStream(PaStream s) => _run('kill-${_sk(s.kind)}-${s.index}', (a, cb, ud) {
    final f = _isSink(s.kind) ? _pa!.kill_sink_input : _pa!.kill_source_output;
    return f(_ctx, s.index, cb, ud);
  });

  @override
  void setCardProfile(PaCard c, String profile) => _run(
    'profile-${c.index}',
    (a, cb, ud) => _pa!.set_card_profile_by_name(_ctx, _s(a)(c.name), _s(a)(profile), cb, ud),
  );

  // --- level meters --------------------------------------------------------------------

  @override
  Stream<double> meter(String source, {int? streamIndex}) {
    late StreamController<double> ctrl;
    int? id;
    ctrl = StreamController<double>(
      onListen: () {
        if (_disposed) return;
        final m = _Meter(source, streamIndex, ctrl);
        id = _nextMeter++;
        _meters[id!] = m;
        if (_ready) _openMeter(m);
      },
      onCancel: () {
        final m = _meters.remove(id);
        if (m != null) _closeMeterStream(m);
        ctrl.close();
      },
    );
    return ctrl.stream;
  }

  /// Peak-detecting record stream, as pavucontrol does it: the server hands us one float32
  /// peak value per 40 ms instead of raw audio.
  void _openMeter(_Meter m) {
    final pa = _pa!;
    final id = _meters.entries.firstWhere((e) => e.value == m).key;
    using((a) {
      final ss = a<pa_sample_spec>()
        ..ref.format = paSampleFloat32le
        ..ref.rate = 25
        ..ref.channels = 1;
      final props = pa.proplist_new();
      void set(String k, String v) =>
          pa.proplist_sets(props, k.toNativeUtf8(allocator: a), v.toNativeUtf8(allocator: a));
      set('application.id', meterAppId);
      set('media.role', 'abstract');
      set('node.passive', 'true');
      final s = pa.stream_new_with_proplist(_ctx, 'Peak detect'.toNativeUtf8(allocator: a), ss, nullptr, props);
      pa.proplist_free(props);
      if (s == nullptr) return;
      if (m.streamIndex != null && pa.stream_set_monitor_stream(s, m.streamIndex!) < 0) {
        pa.stream_unref(s);
        return;
      }
      pa.stream_set_read_callback(s, _readCb.nativeFunction, Pointer.fromAddress(id));
      final attr = a<pa_buffer_attr>()
        ..ref.maxlength = paInvalidIndex
        ..ref.tlength = paInvalidIndex
        ..ref.prebuf = paInvalidIndex
        ..ref.minreq = paInvalidIndex
        ..ref.fragsize = sizeOf<Float>();
      if (pa.stream_connect_record(
            s,
            m.source.toNativeUtf8(allocator: a),
            attr,
            paStreamDontMove | paStreamPeakDetect | paStreamAdjustLatency,
          ) <
          0) {
        pa.stream_set_read_callback(s, nullptr, nullptr);
        pa.stream_unref(s);
        return;
      }
      m.stream = s;
    });
    _kick();
  }

  void _closeMeterStream(_Meter m) {
    if (m.stream == nullptr) return;
    final pa = _pa!;
    pa.stream_set_read_callback(m.stream, nullptr, nullptr);
    pa.stream_disconnect(m.stream);
    pa.stream_unref(m.stream);
    m.stream = nullptr;
  }

  void _onRead(Pointer<Void> s, int nbytes, Pointer<Void> ud) {
    final m = _meters[ud.address];
    final pa = _pa!;
    final data = calloc<Pointer<Void>>();
    final len = calloc<Size>();
    var peak = -1.0;
    try {
      while (pa.stream_peek(s, data, len) == 0 && len.value > 0) {
        if (data.value != nullptr) {
          final f = data.value.cast<Float>();
          for (var k = 0; k < len.value ~/ 4; k++) {
            final v = f[k].abs();
            if (v > peak) peak = v;
          }
        }
        pa.stream_drop(s);
      }
    } finally {
      calloc.free(data);
      calloc.free(len);
    }
    if (m != null && peak >= 0 && !m.ctrl.isClosed) m.ctrl.add(peak.clamp(0.0, 1.0));
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _retry?.cancel();
    _tick?.cancel();
    final pa = _pa;
    if (pa == null) return;
    if (_ctx != nullptr) _teardownContext();
    _meters.clear();
    pa.mainloop_free(_ml);
    _ml = nullptr;
    for (final cb in [
      _stateCb,
      _subscribeCb,
      _successCb,
      _sinkCb,
      _sourceCb,
      _sinkInputCb,
      _sourceOutputCb,
      _cardCb,
      _serverCb,
      _readCb,
    ]) {
      cb.close();
    }
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
