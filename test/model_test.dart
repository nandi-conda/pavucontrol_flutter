import 'package:flutter_test/flutter_test.dart';
import 'package:pavucontrol_flutter/pulse/model.dart';

void main() {
  test('parses pactl json volume and scales locked channels', () {
    final v = ChannelVolumes.parse({
      'front-left': {'value': 65536, 'value_percent': '100%', 'db': '0.00 dB'},
      'front-right': {'value': 32768, 'value_percent': '50%', 'db': '-18.06 dB'},
    });
    expect(v.channels, ['front-left', 'front-right']);
    expect(v.max, volumeNorm);
    expect(v.scaledTo(32768), [32768, 16384]);
    expect(formatDb(volumeNorm), '0.00 dB');
    expect(formatPercent(32768), '50%');
  });

  test('parses a sink', () {
    final d = PaDevice.parse(DeviceKind.sink, {
      'index': 3, 'name': 'alsa_output.x', 'description': 'Speakers', 'mute': false,
      'volume': {'mono': {'value': 40000}}, 'base_volume': {'value': 65536},
      'monitor_source': 'alsa_output.x.monitor', 'flags': ['HARDWARE', 'DECIBEL_VOLUME'],
      'ports': [{'name': 'p1', 'description': 'Speaker', 'availability': 'not available', 'priority': 1}],
      'active_port': 'p1', 'card': 0, 'properties': {},
    });
    expect(d.hardware, isTrue);
    expect(d.meterSource, 'alsa_output.x.monitor');
    expect(d.ports.single.label, 'Speaker (unplugged)');
  });
}
