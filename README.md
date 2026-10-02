# pavucontrol_flutter

A Flutter (Linux desktop) clone of **pavucontrol** — PulseAudio Volume Control — with every menu opening instantly (no menu, page, tab, ripple or button-state animations).

Works with PulseAudio and PipeWire (via pipewire-pulse) by driving `pactl` / `parec`.

## Features
- **Playback / Recording**: per-app volume, mute, lock/unlock channels, move stream to another device ("on …" / "from …"), live level meter, right-click → Terminate
- **Mouse wheel** over any volume slider: ±5% per notch (Shift: ±1%), capped at 153%
- **Output / Input Devices**: volume (with dB + Silence / 100% / Base marks), mute, per-channel sliders, set as fallback, port selection, latency offset (Advanced)
- **Configuration**: card profile selection
- "Show:" filters (Applications / Virtual Streams, Hardware / Virtual / Monitors …)
- Live updates via `pactl subscribe`; follows system light/dark theme

## Install
Prebuilt packages are published to [prefix.dev/channels/nandi-testing](https://prefix.dev/channels/nandi-testing). Its dependencies (gtk3, glib, pulseaudio-client) come from conda-forge, so list both channels:
```sh
pixi global install -c https://prefix.dev/nandi-testing -c conda-forge pavucontrol_flutter
```

## Requirements
- `pactl` ≥ 16 (needs `pactl -f json`) and `parec` — Arch: `sudo pacman -S libpulse` (already present with PipeWire's `pipewire-pulse`)
- Flutter SDK with Linux desktop deps: `sudo pacman -S clang cmake ninja pkgconf gtk3`

## Run
```sh
flutter pub get
flutter run -d linux                    # real audio server
PAVU_MOCK=1 flutter run -d linux        # fake data, for UI work
flutter build linux --release           # -> build/linux/x64/release/bundle/
```

## How "no animations" is done
- Dropdowns use `MenuAnchor(animated: false)`; context menu uses `showMenu(popUpAnimationStyle: AnimationStyle.noAnimation)`
- `TabController(animationDuration: Duration.zero)` and no `TabBarView` swiping
- `NoSplash` everywhere, button hover/press via zero-duration state colors instead of fading ink
- No-op `PageTransitionsTheme`, `themeAnimationDuration: Duration.zero`, custom (non-animated) expanders
