# volume

A Linux clone of **pavucontrol** (PulseAudio Volume Control), written in Nim on
[nimkit](https://github.com/nandi-conda/webby/tree/main/framework), webby's small native UI framework (GTK 3 here).
It started as a Flutter app called `pavucontrol_flutter`; if you installed that, remove it and install `volume`:
`pixi global uninstall pavucontrol_flutter`.

Works with PulseAudio and PipeWire (via pipewire-pulse) by talking to the server directly through libpulse, on
GLib's main loop, without shelling out to any CLI.

## Features
- **Playback / Recording**: per-app volume, mute, lock/unlock channels, move stream to another device ("on …" /
  "from …"), live level meter, Terminate
- **Mouse wheel** or arrow keys over a volume slider: ±5% per step, up to 153%
- **Output / Input Devices**: volume (with dB and Silence / 100% / Base marks), mute, per-channel sliders, set as
  default, port selection, latency offset (Advanced)
- **Configuration**: card profile selection
- "Show:" filters (Applications / Virtual Streams, Hardware / Virtual / Monitors …)
- Live updates via libpulse event subscription; native GTK widgets, so it follows the desktop theme

## Install
Prebuilt packages are published to [prefix.dev/channels/nandi-testing](https://prefix.dev/channels/nandi-testing),
together with the conda-forge packages they need, so the channel works on its own:
```sh
pixi global install -c https://prefix.dev/nandi-testing volume
```
This also adds a "Volume Control" entry to your desktop's app menu (via menuinst).

## Build and run
nimkit comes from the webby repo as a git submodule (`vendor/webby`); the pixi tasks fetch it.
```sh
pixi run volume         # build into build/ and run against your audio server
pixi run mock           # made-up devices and streams (PAVU_MOCK=1), for UI work
pixi run test
pixi run package        # the conda package, into output/
```

## Layout
```
src/volume.nim   the UI: tabs, tiles per stream / device / card, filters
src/pulse.nim         libpulse (asynchronous API on the GLib main loop), request coalescing, level meters, mock
src/model.nim         devices, streams, cards; volume maths and formatting
vendor/webby          nimkit (framework/src)
packaging/            desktop entry, icons, menuinst menu
packages/             pulseaudio-libs (libpulse without the CLIs) and mesa, published alongside
```
