import 'dart:math' as math;

/// PA_VOLUME_NORM (100%).
const int volumeNorm = 0x10000;

/// pavucontrol's slider maximum (~153%, i.e. +11 dB).
const int volumeUiMax = 100270;

int? asInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) {
    final m = RegExp(r'-?\d+').firstMatch(v);
    return m == null ? null : int.parse(m.group(0)!);
  }
  return null;
}

bool asBool(dynamic v) {
  if (v is bool) return v;
  if (v is String) return v == 'yes' || v == 'true' || v == '1';
  if (v is num) return v != 0;
  return false;
}

String? asName(dynamic v) {
  if (v is String && v.isNotEmpty && v != 'n/a' && v != '(null)') return v;
  return null;
}

Map<String, String> asProps(dynamic v) {
  if (v is Map) return v.map((k, val) => MapEntry('$k', '$val'));
  return const {};
}

/// Volume in dB as PulseAudio computes it for software volumes.
double volumeToDb(int v) {
  if (v <= 0) return double.negativeInfinity;
  return 60 * math.log(v / volumeNorm) / math.ln10;
}

String formatPercent(int v) => '${(v * 100 / volumeNorm).round()}%';

String formatDb(int v) {
  final db = volumeToDb(v);
  if (db.isInfinite) return '-∞ dB';
  return '${db.toStringAsFixed(2)} dB';
}

const _channelNames = {
  'mono': 'Mono',
  'front-left': 'Front Left',
  'front-right': 'Front Right',
  'front-center': 'Front Center',
  'rear-left': 'Rear Left',
  'rear-right': 'Rear Right',
  'rear-center': 'Rear Center',
  'lfe': 'Subwoofer',
  'side-left': 'Side Left',
  'side-right': 'Side Right',
  'front-left-of-center': 'Front Left of Center',
  'front-right-of-center': 'Front Right of Center',
  'top-center': 'Top Center',
  'top-front-left': 'Top Front Left',
  'top-front-right': 'Top Front Right',
  'top-front-center': 'Top Front Center',
  'top-rear-left': 'Top Rear Left',
  'top-rear-right': 'Top Rear Right',
  'top-rear-center': 'Top Rear Center',
};

String prettyChannel(String c) => _channelNames[c] ??
    c.split('-').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');

class ChannelVolumes {
  final List<String> channels;
  final List<int> values;
  const ChannelVolumes(this.channels, this.values);

  static const empty = ChannelVolumes([], []);

  bool get isEmpty => values.isEmpty;

  int get max => values.isEmpty ? 0 : values.reduce(math.max);

  /// Scales all channels so the loudest equals [v] (pa_cvolume_scale).
  List<int> scaledTo(int v) {
    final m = max;
    if (m == 0) return List.filled(values.length, v);
    return [for (final c in values) (c * v / m).round().clamp(0, 0x7fffffff)];
  }

  static ChannelVolumes parse(dynamic json) {
    if (json is! Map) return empty;
    final ch = <String>[];
    final vals = <int>[];
    json.forEach((k, v) {
      final raw = v is Map ? asInt(v['value']) : asInt(v);
      if (raw != null) {
        ch.add('$k');
        vals.add(raw);
      }
    });
    return ChannelVolumes(ch, vals);
  }
}

class PaPort {
  final String name;
  final String description;
  final bool available; // false only when explicitly "not available"
  final int priority;
  final int latencyOffsetUsec;
  const PaPort(this.name, this.description, this.available, this.priority,
      [this.latencyOffsetUsec = 0]);

  static PaPort parse(dynamic j) {
    final m = j is Map ? j : const {};
    final avail = '${m['availability'] ?? ''}'.toLowerCase();
    return PaPort(
      '${m['name'] ?? ''}',
      asName(m['description']) ?? '${m['name'] ?? ''}',
      !avail.contains('not available'),
      asInt(m['priority']) ?? 0,
      asInt(m['latency_offset']) ?? 0,
    );
  }

  String get label => available ? description : '$description (unplugged)';
}

enum DeviceKind { sink, source }

class PaDevice {
  final DeviceKind kind;
  final int index;
  final String name;
  final String description;
  final bool mute;
  final ChannelVolumes volume;
  final int baseVolume;
  final bool decibel;
  final bool hardware;
  final String? monitorSource; // sinks: their monitor source
  final String? monitorOfSink; // sources: set if this is a monitor
  final List<PaPort> ports;
  final String? activePort;
  final int? card;
  final Map<String, String> props;

  const PaDevice({
    required this.kind,
    required this.index,
    required this.name,
    required this.description,
    required this.mute,
    required this.volume,
    required this.baseVolume,
    required this.decibel,
    required this.hardware,
    required this.monitorSource,
    required this.monitorOfSink,
    required this.ports,
    required this.activePort,
    required this.card,
    required this.props,
  });

  bool get isMonitor => monitorOfSink != null;

  String get iconName =>
      props['device.icon_name'] ??
      (kind == DeviceKind.sink ? 'audio-card' : 'audio-input-microphone');

  /// Source to record from for a level meter.
  String get meterSource => kind == DeviceKind.sink ? (monitorSource ?? '$name.monitor') : name;

  static PaDevice parse(DeviceKind kind, Map j) {
    final flags = (j['flags'] is List) ? (j['flags'] as List).map((e) => '$e').toSet() : <String>{};
    final props = asProps(j['properties']);
    final base = j['base_volume'];
    return PaDevice(
      kind: kind,
      index: asInt(j['index']) ?? -1,
      name: '${j['name'] ?? ''}',
      description: asName(j['description']) ?? '${j['name'] ?? ''}',
      mute: asBool(j['mute']),
      volume: ChannelVolumes.parse(j['volume']),
      baseVolume: (base is Map ? asInt(base['value']) : asInt(base)) ?? volumeNorm,
      decibel: flags.isEmpty || flags.contains('DECIBEL_VOLUME'),
      hardware: flags.contains('HARDWARE') || props.containsKey('alsa.card') || props['device.api'] == 'bluez5',
      monitorSource: kind == DeviceKind.sink ? asName(j['monitor_source']) : null,
      // pactl's JSON reports a source's monitored sink under "monitor_source".
      monitorOfSink: kind == DeviceKind.source
          ? (asName(j['monitor_of_sink']) ??
              asName(j['monitor_source']) ??
              (props['device.class'] == 'monitor' ? '${j['name']}' : null))
          : null,
      ports: (j['ports'] is List) ? [for (final p in j['ports'] as List) PaPort.parse(p)] : const [],
      activePort: asName(j['active_port']),
      card: asInt(j['card']),
      props: props,
    );
  }
}

class PaStream {
  final DeviceKind kind; // sink => playback (sink-input), source => recording (source-output)
  final int index;
  final int? client;
  final int device;
  final bool mute;
  final bool corked;
  final ChannelVolumes volume;
  final Map<String, String> props;

  const PaStream({
    required this.kind,
    required this.index,
    required this.client,
    required this.device,
    required this.mute,
    required this.corked,
    required this.volume,
    required this.props,
  });

  bool get hasVolume => !volume.isEmpty;
  bool get isVirtual => client == null;

  String get appName =>
      props['application.name'] ?? props['application.process.binary'] ?? props['node.name'] ?? 'Unknown';
  String get mediaName => props['media.name'] ?? '';
  String get iconName => props['application.icon_name'] ?? props['media.icon_name'] ?? '';

  String get title {
    final m = mediaName;
    if (m.isEmpty || m == appName) return appName;
    return '$appName: $m';
  }

  static PaStream parse(DeviceKind kind, Map j) => PaStream(
        kind: kind,
        index: asInt(j['index']) ?? -1,
        client: asInt(j['client']),
        device: asInt(kind == DeviceKind.sink ? j['sink'] : j['source']) ?? -1,
        mute: asBool(j['mute']),
        corked: asBool(j['corked']),
        volume: ChannelVolumes.parse(j['volume']),
        props: asProps(j['properties']),
      );
}

class PaProfile {
  final String name;
  final String description;
  final bool available;
  final int priority;
  const PaProfile(this.name, this.description, this.available, this.priority);

  String get label => available ? description : '$description (unavailable)';
}

class PaCard {
  final int index;
  final String name;
  final String description;
  final List<PaProfile> profiles;
  final String? activeProfile;
  final List<PaPort> ports;
  final Map<String, String> props;

  const PaCard(this.index, this.name, this.description, this.profiles, this.activeProfile, this.ports,
      this.props);

  String get iconName => props['device.icon_name'] ?? 'audio-card';

  static PaCard parse(Map j) {
    final props = asProps(j['properties']);
    final profiles = <PaProfile>[];
    final pj = j['profiles'];
    if (pj is Map) {
      pj.forEach((k, v) {
        final m = v is Map ? v : const {};
        profiles.add(PaProfile('$k', asName(m['description']) ?? '$k',
            m.containsKey('available') ? asBool(m['available']) : true, asInt(m['priority']) ?? 0));
      });
    } else if (pj is List) {
      for (final v in pj) {
        if (v is Map) {
          profiles.add(PaProfile('${v['name']}', asName(v['description']) ?? '${v['name']}',
              v.containsKey('available') ? asBool(v['available']) : true, asInt(v['priority']) ?? 0));
        }
      }
    }
    profiles.sort((a, b) => b.priority.compareTo(a.priority));
    final ports = <PaPort>[];
    final portsJ = j['ports'];
    if (portsJ is Map) {
      portsJ.forEach((k, v) {
        final m = Map<String, dynamic>.from(v is Map ? v : const {});
        m['name'] ??= '$k';
        ports.add(PaPort.parse(m));
      });
    } else if (portsJ is List) {
      ports.addAll(portsJ.map(PaPort.parse));
    }
    return PaCard(
      asInt(j['index']) ?? -1,
      '${j['name'] ?? ''}',
      props['device.description'] ?? '${j['name'] ?? ''}',
      profiles,
      asName(j['active_profile']),
      ports,
      props,
    );
  }
}

class PaState {
  final List<PaDevice> sinks;
  final List<PaDevice> sources;
  final List<PaStream> sinkInputs;
  final List<PaStream> sourceOutputs;
  final List<PaCard> cards;
  final String? defaultSink;
  final String? defaultSource;
  final String? error;
  final bool loaded;

  const PaState({
    this.sinks = const [],
    this.sources = const [],
    this.sinkInputs = const [],
    this.sourceOutputs = const [],
    this.cards = const [],
    this.defaultSink,
    this.defaultSource,
    this.error,
    this.loaded = false,
  });

  PaCard? cardFor(PaDevice d) {
    for (final c in cards) {
      if (c.index == d.card) return c;
    }
    return null;
  }
}
