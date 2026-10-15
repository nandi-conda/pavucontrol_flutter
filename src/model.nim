## What the volume control shows: the server's devices, streams and cards as plain Nim values, and how volumes are
## written out. Filled in by pulse.nim (from libpulse) or by its mock.

import std/[math, strutils, tables]

const
  volumeNorm* = 0x10000      ## PA_VOLUME_NORM, 100%
  volumeUiMax* = 100270      ## pavucontrol's slider maximum (~153%, +11 dB)

type
  DeviceKind* = enum dkSink, dkSource

  Port* = object
    name*, description*: string
    available*: bool         ## false only when the server says it is unplugged
    priority*: int
    latencyOffsetUsec*: int64

  Device* = object
    kind*: DeviceKind
    index*: int
    name*, description*: string
    mute*: bool
    channels*: seq[string]   ## channel names ("front-left", ...), one per volume
    volume*: seq[int]
    baseVolume*: int
    decibel*: bool
    hardware*: bool
    monitorSource*: string   ## sinks: their monitor source
    monitorOfSink*: string   ## sources: the sink they monitor, "" if not a monitor
    ports*: seq[Port]
    activePort*: string
    card*: int               ## -1 if none
    props*: Table[string, string]

  Stream* = object
    kind*: DeviceKind        ## dkSink: playback (sink input); dkSource: recording (source output)
    index*: int
    client*: int             ## -1 for streams without a client (virtual)
    device*: int             ## the sink or source it plays to / records from, -1 if none
    mute*, corked*: bool
    channels*: seq[string]
    volume*: seq[int]        ## empty when the stream has no volume
    props*: Table[string, string]

  Profile* = object
    name*, description*: string
    available*: bool
    priority*: int

  Card* = object
    index*: int
    name*, description*: string
    profiles*: seq[Profile]  ## highest priority first
    activeProfile*: string
    ports*: seq[Port]
    props*: Table[string, string]

  State* = object
    loaded*: bool            ## false until the first full read from the server
    error*: string           ## set while there is no connection
    sinks*, sources*: seq[Device]
    sinkInputs*, sourceOutputs*: seq[Stream]
    cards*: seq[Card]
    defaultSink*, defaultSource*: string

proc isMonitor*(d: Device): bool = d.monitorOfSink.len > 0

proc meterSource*(d: Device): string =
  ## The source to read a level meter from: a sink's monitor, or the source itself.
  if d.kind == dkSink: (if d.monitorSource.len > 0: d.monitorSource else: d.name & ".monitor") else: d.name

proc hasVolume*(s: Stream): bool = s.volume.len > 0
proc isVirtual*(s: Stream): bool = s.client < 0

proc appName*(s: Stream): string =
  for key in ["application.name", "application.process.binary", "node.name"]:
    if s.props.getOrDefault(key).len > 0: return s.props[key]
  "Unknown"

proc mediaName*(s: Stream): string = s.props.getOrDefault("media.name")

proc title*(s: Stream): string =
  let m = s.mediaName
  if m.len == 0 or m == s.appName: s.appName else: s.appName & ": " & m

proc label*(p: Port): string =
  if p.available: p.description else: p.description & " (unplugged)"

proc label*(p: Profile): string =
  if p.available: p.description else: p.description & " (unavailable)"

proc cardFor*(st: var State, d: Device): ptr Card =
  for c in st.cards.mitems:
    if c.index == d.card: return addr c

proc loudest*(volume: seq[int]): int =
  for v in volume: result = max(result, v)

proc scaledTo*(volume: seq[int], v: int): seq[int] =
  ## All channels scaled so the loudest is `v` (pa_cvolume_scale).
  let m = volume.loudest
  for c in volume:
    result.add(if m == 0: v else: int(round(c.float * v.float / m.float)).clamp(0, 0x7fffffff))

proc volumeToDb*(v: int): float =
  ## As PulseAudio computes it for software volumes.
  if v <= 0: NegInf else: 60 * log10(v / volumeNorm)

proc formatPercent*(v: int): string = $int(round(v * 100 / volumeNorm)) & "%"

proc formatDb*(v: int): string =
  let db = volumeToDb(v)
  if db == NegInf: "-∞ dB" else: formatFloat(db, ffDecimal, 2) & " dB"

const channelNames = {
  "mono": "Mono", "front-left": "Front Left", "front-right": "Front Right", "front-center": "Front Center",
  "rear-left": "Rear Left", "rear-right": "Rear Right", "rear-center": "Rear Center", "lfe": "Subwoofer",
  "side-left": "Side Left", "side-right": "Side Right", "front-left-of-center": "Front Left of Center",
  "front-right-of-center": "Front Right of Center", "top-center": "Top Center", "top-front-left": "Top Front Left",
  "top-front-right": "Top Front Right", "top-front-center": "Top Front Center", "top-rear-left": "Top Rear Left",
  "top-rear-right": "Top Rear Right", "top-rear-center": "Top Rear Center"}.toTable

proc prettyChannel*(c: string): string =
  ## "front-left" -> "Front Left"; unknown names are capitalized word by word.
  if c in channelNames: return channelNames[c]
  for word in c.split('-'):
    if result.len > 0: result.add ' '
    result.add word.capitalizeAscii
