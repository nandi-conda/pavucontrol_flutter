## Talks to PulseAudio (or PipeWire's pipewire-pulse) through libpulse's asynchronous API, on GLib's main loop, the
## same one GTK runs: every libpulse callback comes on the UI thread, while its info structs are still valid.
##
## `state` holds what the server has; `onChange` runs after it changes. Requests (volume, mute, ...) are coalesced
## per control: while one is with the server only the newest next one waits, so slider drags stay smooth.
## With PAVU_MOCK=1 the module serves made-up devices and streams instead (for UI work without a server).

import std/[math, os, random, tables]
import nimkit
import model

{.passC: gorge("pkg-config --cflags libpulse libpulse-mainloop-glib").}
{.passL: gorge("pkg-config --libs libpulse libpulse-mainloop-glib").}
# libpulse's callbacks take const pointers, which Nim can't spell; the layouts are the header's, so let them pass.
{.passC: "-Wno-incompatible-pointer-types -Wno-discarded-qualifiers".}

const
  pulseH = "<pulse/pulseaudio.h>"
  meterAppId* = "dev.v.volume.meter"   ## marks our own meter streams, hidden from Recording

type
  PaContext {.importc: "pa_context", header: pulseH, incompleteStruct.} = object
  PaOperation {.importc: "pa_operation", header: pulseH, incompleteStruct.} = object
  PaProplist {.importc: "pa_proplist", header: pulseH, incompleteStruct.} = object
  PaStreamC {.importc: "pa_stream", header: pulseH, incompleteStruct.} = object
  PaMainloopApi {.importc: "pa_mainloop_api", header: pulseH, incompleteStruct.} = object
  PaGlibMainloop {.importc: "pa_glib_mainloop", header: "<pulse/glib-mainloop.h>", incompleteStruct.} = object

  PaSampleSpec {.importc: "pa_sample_spec", header: pulseH.} = object
    format: cint
    rate: uint32
    channels: uint8
  PaChannelMap {.importc: "pa_channel_map", header: pulseH.} = object
    channels: uint8
    map: array[32, cint]
  PaCVolume {.importc: "pa_cvolume", header: pulseH.} = object
    channels: uint8
    values: array[32, uint32]
  PaBufferAttr {.importc: "pa_buffer_attr", header: pulseH.} = object
    maxlength, tlength, prebuf, minreq, fragsize: uint32

  PaPortInfo {.importc: "pa_sink_port_info", header: pulseH.} = object   # pa_source_port_info is the same
    name, description: cstring
    priority: uint32
    available: cint
  PaSinkInfo {.importc: "pa_sink_info", header: pulseH.} = object
    name: cstring
    index: uint32
    description: cstring
    channel_map: PaChannelMap
    volume: PaCVolume
    mute: cint
    monitor_source_name: cstring
    flags: cint
    proplist: ptr PaProplist
    base_volume: uint32
    card: uint32
    n_ports: uint32
    ports: ptr UncheckedArray[ptr PaPortInfo]
    active_port: ptr PaPortInfo
  PaSourceInfo {.importc: "pa_source_info", header: pulseH.} = object
    name: cstring
    index: uint32
    description: cstring
    channel_map: PaChannelMap
    volume: PaCVolume
    mute: cint
    monitor_of_sink_name: cstring
    flags: cint
    proplist: ptr PaProplist
    base_volume: uint32
    card: uint32
    n_ports: uint32
    ports: ptr UncheckedArray[ptr PaPortInfo]
    active_port: ptr PaPortInfo
  PaSinkInputInfo {.importc: "pa_sink_input_info", header: pulseH.} = object
    index, client, sink: uint32
    channel_map: PaChannelMap
    volume: PaCVolume
    mute: cint
    proplist: ptr PaProplist
    corked, has_volume: cint
  PaSourceOutputInfo {.importc: "pa_source_output_info", header: pulseH.} = object
    index, client, source: uint32
    channel_map: PaChannelMap
    volume: PaCVolume
    mute: cint
    proplist: ptr PaProplist
    corked, has_volume: cint
  PaCardProfileInfo2 {.importc: "pa_card_profile_info2", header: pulseH.} = object
    name, description: cstring
    priority: uint32
    available: cint
  PaCardPortInfo {.importc: "pa_card_port_info", header: pulseH.} = object
    name, description: cstring
    priority: uint32
    available: cint
    latency_offset: int64
  PaCardInfo {.importc: "pa_card_info", header: pulseH.} = object
    index: uint32
    name: cstring
    n_profiles: uint32
    proplist: ptr PaProplist
    n_ports: uint32
    ports: ptr UncheckedArray[ptr PaCardPortInfo]
    profiles2: ptr UncheckedArray[ptr PaCardProfileInfo2]
    active_profile2: ptr PaCardProfileInfo2
  PaServerInfo {.importc: "pa_server_info", header: pulseH.} = object
    default_sink_name, default_source_name: cstring

  SuccessCb = proc (c: ptr PaContext, success: cint, ud: pointer) {.cdecl.}
  InfoCb[T] = proc (c: ptr PaContext, i: ptr T, eol: cint, ud: pointer) {.cdecl.}

const
  PA_CONTEXT_READY = 4.cint
  PA_CONTEXT_FAILED = 5.cint
  PA_CONTEXT_TERMINATED = 6.cint
  PA_SUBSCRIPTION_MASK_ALL = 0x02ff.cint
  PA_SAMPLE_FLOAT32LE = 5.cint
  PA_STREAM_DONT_MOVE = 0x0200.cint
  PA_STREAM_PEAK_DETECT = 0x0800.cint
  PA_STREAM_ADJUST_LATENCY = 0x2000.cint
  PA_SINK_HARDWARE = 0x0004.cint      # same bits for sources
  PA_SINK_DECIBEL_VOLUME = 0x0020.cint
  PA_PORT_AVAILABLE_NO = 1.cint
  PA_INVALID_INDEX = 0xffffffff'u32

{.push importc, cdecl, header: pulseH.}
proc pa_proplist_new(): ptr PaProplist
proc pa_proplist_free(p: ptr PaProplist)
proc pa_proplist_sets(p: ptr PaProplist, key, value: cstring): cint
proc pa_proplist_gets(p: ptr PaProplist, key: cstring): cstring
proc pa_proplist_iterate(p: ptr PaProplist, state: ptr pointer): cstring
proc pa_channel_position_to_string(pos: cint): cstring
proc pa_strerror(error: cint): cstring
proc pa_operation_unref(o: ptr PaOperation)
proc pa_context_new_with_proplist(api: ptr PaMainloopApi, name: cstring, props: ptr PaProplist): ptr PaContext
proc pa_context_unref(c: ptr PaContext)
proc pa_context_connect(c: ptr PaContext, server: cstring, flags: cint, api: pointer): cint
proc pa_context_disconnect(c: ptr PaContext)
proc pa_context_get_state(c: ptr PaContext): cint
proc pa_context_errno(c: ptr PaContext): cint
proc pa_context_set_state_callback(c: ptr PaContext, cb: proc (c: ptr PaContext, ud: pointer) {.cdecl.}, ud: pointer)
proc pa_context_set_subscribe_callback(c: ptr PaContext,
    cb: proc (c: ptr PaContext, t: cint, idx: uint32, ud: pointer) {.cdecl.}, ud: pointer)
proc pa_context_subscribe(c: ptr PaContext, mask: cint, cb: SuccessCb, ud: pointer): ptr PaOperation
proc pa_context_get_sink_info_list(c: ptr PaContext, cb: InfoCb[PaSinkInfo], ud: pointer): ptr PaOperation
proc pa_context_get_source_info_list(c: ptr PaContext, cb: InfoCb[PaSourceInfo], ud: pointer): ptr PaOperation
proc pa_context_get_sink_input_info_list(c: ptr PaContext, cb: InfoCb[PaSinkInputInfo], ud: pointer): ptr PaOperation
proc pa_context_get_source_output_info_list(c: ptr PaContext, cb: InfoCb[PaSourceOutputInfo],
                                            ud: pointer): ptr PaOperation
proc pa_context_get_card_info_list(c: ptr PaContext, cb: InfoCb[PaCardInfo], ud: pointer): ptr PaOperation
proc pa_context_get_server_info(c: ptr PaContext,
    cb: proc (c: ptr PaContext, i: ptr PaServerInfo, ud: pointer) {.cdecl.}, ud: pointer): ptr PaOperation
proc pa_context_set_sink_volume_by_name(c: ptr PaContext, name: cstring, v: ptr PaCVolume, cb: SuccessCb,
                                        ud: pointer): ptr PaOperation
proc pa_context_set_source_volume_by_name(c: ptr PaContext, name: cstring, v: ptr PaCVolume, cb: SuccessCb,
                                          ud: pointer): ptr PaOperation
proc pa_context_set_sink_mute_by_name(c: ptr PaContext, name: cstring, mute: cint, cb: SuccessCb,
                                      ud: pointer): ptr PaOperation
proc pa_context_set_source_mute_by_name(c: ptr PaContext, name: cstring, mute: cint, cb: SuccessCb,
                                        ud: pointer): ptr PaOperation
proc pa_context_set_default_sink(c: ptr PaContext, name: cstring, cb: SuccessCb, ud: pointer): ptr PaOperation
proc pa_context_set_default_source(c: ptr PaContext, name: cstring, cb: SuccessCb, ud: pointer): ptr PaOperation
proc pa_context_set_sink_port_by_name(c: ptr PaContext, name, port: cstring, cb: SuccessCb,
                                      ud: pointer): ptr PaOperation
proc pa_context_set_source_port_by_name(c: ptr PaContext, name, port: cstring, cb: SuccessCb,
                                        ud: pointer): ptr PaOperation
proc pa_context_set_port_latency_offset(c: ptr PaContext, card, port: cstring, offset: int64, cb: SuccessCb,
                                        ud: pointer): ptr PaOperation
proc pa_context_set_sink_input_volume(c: ptr PaContext, idx: uint32, v: ptr PaCVolume, cb: SuccessCb,
                                      ud: pointer): ptr PaOperation
proc pa_context_set_source_output_volume(c: ptr PaContext, idx: uint32, v: ptr PaCVolume, cb: SuccessCb,
                                         ud: pointer): ptr PaOperation
proc pa_context_set_sink_input_mute(c: ptr PaContext, idx: uint32, mute: cint, cb: SuccessCb,
                                    ud: pointer): ptr PaOperation
proc pa_context_set_source_output_mute(c: ptr PaContext, idx: uint32, mute: cint, cb: SuccessCb,
                                       ud: pointer): ptr PaOperation
proc pa_context_move_sink_input_by_name(c: ptr PaContext, idx: uint32, sink: cstring, cb: SuccessCb,
                                        ud: pointer): ptr PaOperation
proc pa_context_move_source_output_by_name(c: ptr PaContext, idx: uint32, source: cstring, cb: SuccessCb,
                                           ud: pointer): ptr PaOperation
proc pa_context_kill_sink_input(c: ptr PaContext, idx: uint32, cb: SuccessCb, ud: pointer): ptr PaOperation
proc pa_context_kill_source_output(c: ptr PaContext, idx: uint32, cb: SuccessCb, ud: pointer): ptr PaOperation
proc pa_context_set_card_profile_by_name(c: ptr PaContext, card, profile: cstring, cb: SuccessCb,
                                         ud: pointer): ptr PaOperation
proc pa_stream_new_with_proplist(c: ptr PaContext, name: cstring, ss: ptr PaSampleSpec, map: pointer,
                                 props: ptr PaProplist): ptr PaStreamC
proc pa_stream_unref(s: ptr PaStreamC)
proc pa_stream_set_monitor_stream(s: ptr PaStreamC, idx: uint32): cint
proc pa_stream_set_read_callback(s: ptr PaStreamC, cb: proc (s: ptr PaStreamC, n: csize_t, ud: pointer) {.cdecl.},
                                 ud: pointer)
proc pa_stream_connect_record(s: ptr PaStreamC, dev: cstring, attr: ptr PaBufferAttr, flags: cint): cint
proc pa_stream_disconnect(s: ptr PaStreamC): cint
proc pa_stream_peek(s: ptr PaStreamC, data: ptr pointer, n: ptr csize_t): cint
proc pa_stream_drop(s: ptr PaStreamC): cint
{.pop.}
proc pa_glib_mainloop_new(ctx: pointer): ptr PaGlibMainloop {.importc, cdecl, header: "<pulse/glib-mainloop.h>".}
proc pa_glib_mainloop_get_api(m: ptr PaGlibMainloop): ptr PaMainloopApi
  {.importc, cdecl, header: "<pulse/glib-mainloop.h>".}

# ---------------------------------------------------------------------------------------------------------------
# State

var
  state*: State
  onChange*: proc ()            ## runs after `state` changed
  mock = getEnv("PAVU_MOCK") == "1"
  mainloop: ptr PaGlibMainloop
  ctx: ptr PaContext
  ready = false

proc changed() =
  if onChange != nil: onChange()

proc str(s: cstring): string =
  ## libpulse's strings, with "(null)" and "n/a" as empty.
  if s == nil: return ""
  result = $s
  if result in ["(null)", "n/a"]: result = ""

proc props(p: ptr PaProplist): Table[string, string] =
  if p == nil: return
  var it: pointer
  while true:
    let key = pa_proplist_iterate(p, addr it)
    if key == nil: break
    let v = pa_proplist_gets(p, key)
    if v != nil: result[$key] = $v

proc volume(v: PaCVolume, map: PaChannelMap): (seq[string], seq[int]) =
  for k in 0 ..< min(v.channels.int, 32):
    result[0].add(if k < map.channels.int: $pa_channel_position_to_string(map.map[k]) else: "aux" & $k)
    result[1].add v.values[k].int

proc index(i: uint32): int = (if i == PA_INVALID_INDEX: -1 else: i.int)

# --- Refreshing: on every server event, read everything again (debounced) ---------------------------------------

type Snapshot = ref object
  st: State
  pending: int

var
  snap: Snapshot
  refreshing, dirty: bool
  debounce: Timer

proc refresh()

proc scheduleRefresh() =
  debounce.cancel()
  debounce = after(40, refresh)

proc partDone() =
  dec snap.pending
  if snap.pending > 0: return
  state = snap.st
  state.loaded = true
  snap = nil
  refreshing = false
  changed()
  if dirty:
    dirty = false
    scheduleRefresh()

template current(ud: pointer): Snapshot =
  # Answers for an older refresh (from before a reconnect) are dropped.
  (if snap != nil and cast[pointer](snap) == ud: snap else: nil)

proc device[T](kind: DeviceKind, i: ptr T): Device =
  let p = props(i.proplist)
  let (chans, vols) = volume(i.volume, i.channel_map)
  result = Device(kind: kind, index: i.index.int, name: str(i.name), mute: i.mute != 0, channels: chans,
                  volume: vols, baseVolume: i.base_volume.int, card: index(i.card), props: p,
                  decibel: i.flags == 0 or (i.flags and PA_SINK_DECIBEL_VOLUME) != 0,
                  activePort: (if i.active_port == nil: "" else: str(i.active_port.name)))
  result.description = str(i.description)
  if result.description.len == 0: result.description = result.name
  result.hardware = (i.flags and PA_SINK_HARDWARE) != 0 or "alsa.card" in p or p.getOrDefault("device.api") == "bluez5"
  for k in 0 ..< i.n_ports.int:
    let port = i.ports[k]
    if port == nil: continue
    var d = str(port.description)
    if d.len == 0: d = str(port.name)
    result.ports.add Port(name: str(port.name), description: d, available: port.available != PA_PORT_AVAILABLE_NO,
                          priority: port.priority.int)

proc onSink(c: ptr PaContext, i: ptr PaSinkInfo, eol: cint, ud: pointer) {.cdecl.} =
  let s = current(ud)
  if s == nil: return
  if eol != 0:
    partDone()
    return
  var d = device(dkSink, i)
  d.monitorSource = str(i.monitor_source_name)
  s.st.sinks.add d

proc onSource(c: ptr PaContext, i: ptr PaSourceInfo, eol: cint, ud: pointer) {.cdecl.} =
  let s = current(ud)
  if s == nil: return
  if eol != 0:
    partDone()
    return
  var d = device(dkSource, i)
  d.monitorOfSink = str(i.monitor_of_sink_name)
  if d.monitorOfSink.len == 0 and d.props.getOrDefault("device.class") == "monitor": d.monitorOfSink = d.name
  s.st.sources.add d

proc stream[T](kind: DeviceKind, i: ptr T, device: uint32): Stream =
  result = Stream(kind: kind, index: i.index.int, client: index(i.client), device: index(device),
                  mute: i.mute != 0, corked: i.corked != 0, props: props(i.proplist))
  if i.has_volume != 0: (result.channels, result.volume) = volume(i.volume, i.channel_map)

proc onSinkInput(c: ptr PaContext, i: ptr PaSinkInputInfo, eol: cint, ud: pointer) {.cdecl.} =
  let s = current(ud)
  if s == nil: return
  if eol != 0:
    partDone()
    return
  s.st.sinkInputs.add stream(dkSink, i, i.sink)

proc onSourceOutput(c: ptr PaContext, i: ptr PaSourceOutputInfo, eol: cint, ud: pointer) {.cdecl.} =
  let s = current(ud)
  if s == nil: return
  if eol != 0:
    partDone()
    return
  let st = stream(dkSource, i, i.source)
  if st.props.getOrDefault("application.id") != meterAppId: s.st.sourceOutputs.add st

proc onCard(c: ptr PaContext, i: ptr PaCardInfo, eol: cint, ud: pointer) {.cdecl.} =
  let s = current(ud)
  if s == nil: return
  if eol != 0:
    partDone()
    return
  var card = Card(index: i.index.int, name: str(i.name), props: props(i.proplist))
  card.description = card.props.getOrDefault("device.description", card.name)
  if i.active_profile2 != nil: card.activeProfile = str(i.active_profile2.name)
  if i.profiles2 != nil:
    for k in 0 ..< i.n_profiles.int:
      let p = i.profiles2[k]
      if p == nil: continue
      var d = str(p.description)
      if d.len == 0: d = str(p.name)
      card.profiles.add Profile(name: str(p.name), description: d, available: p.available != 0,
                                priority: p.priority.int)
  # Highest priority first, ties in the server's order.
  var sorted: seq[Profile]
  for p in card.profiles:
    var at = sorted.len
    while at > 0 and sorted[at - 1].priority < p.priority: dec at
    sorted.insert(p, at)
  card.profiles = sorted
  for k in 0 ..< i.n_ports.int:
    let p = i.ports[k]
    if p == nil: continue
    var d = str(p.description)
    if d.len == 0: d = str(p.name)
    card.ports.add Port(name: str(p.name), description: d, available: p.available != PA_PORT_AVAILABLE_NO,
                        priority: p.priority.int, latencyOffsetUsec: p.latency_offset)
  s.st.cards.add card

proc onServer(c: ptr PaContext, i: ptr PaServerInfo, ud: pointer) {.cdecl.} =
  let s = current(ud)
  if s == nil: return
  if i != nil:
    s.st.defaultSink = str(i.default_sink_name)
    s.st.defaultSource = str(i.default_source_name)
  partDone()

proc refresh() =
  if not ready: return
  if refreshing:
    dirty = true
    return
  refreshing = true
  snap = Snapshot(pending: 6)
  let ud = cast[pointer](snap)
  for op in [pa_context_get_sink_info_list(ctx, onSink, ud), pa_context_get_source_info_list(ctx, onSource, ud),
             pa_context_get_sink_input_info_list(ctx, onSinkInput, ud),
             pa_context_get_source_output_info_list(ctx, onSourceOutput, ud),
             pa_context_get_card_info_list(ctx, onCard, ud), pa_context_get_server_info(ctx, onServer, ud)]:
    if op == nil: partDone()   # failed at once; counts as answered
    else: pa_operation_unref(op)

# --- Requests ---------------------------------------------------------------------------------------------------

type Issue = proc (cb: SuccessCb, ud: pointer): ptr PaOperation

var
  pendingReq: Table[string, Issue]   # control -> its newest request not sent yet
  inFlight: Table[string, int]       # control -> the op id the server is working on
  opKeys: Table[int, string]
  nextOp = 1

proc issue(key: string)

proc onSuccess(c: ptr PaContext, success: cint, ud: pointer) {.cdecl.} =
  let id = cast[int](ud)
  if id notin opKeys: return
  let key = opKeys[id]
  opKeys.del id
  inFlight.del key
  if key in pendingReq: issue(key)

proc issue(key: string) =
  if key notin pendingReq: return
  let f = pendingReq[key]
  pendingReq.del key
  if not ready: return
  let id = nextOp
  inc nextOp
  let op = f(onSuccess, cast[pointer](id))
  if op == nil:   # rejected locally (a bad argument): try the next one, if any
    if key in pendingReq: issue(key)
    return
  opKeys[id] = key
  inFlight[key] = id
  pa_operation_unref(op)

proc run(key: string, f: Issue) =
  pendingReq[key] = f
  if key notin inFlight: issue(key)

proc toConst(s: seq[int], v: int): seq[int] =
  for _ in s: result.add v

proc cvolume(values: seq[int], channels: int): PaCVolume =
  var v = values
  if v.len == 1 and channels > 1: v = newSeq[int](channels).toConst(values[0])
  result.channels = min(v.len, 32).uint8
  for k in 0 ..< result.channels.int: result.values[k] = v[k].clamp(0, 0x7fffffff).uint32


# --- Mock ------------------------------------------------------------------------------------------------------

proc mockDevice(st: var State, d: Device) =
  for x in st.sinks.mitems:
    if x.kind == d.kind and x.index == d.index: x = d
  for x in st.sources.mitems:
    if x.kind == d.kind and x.index == d.index: x = d

proc mockStream(st: var State, s: Stream) =
  for x in st.sinkInputs.mitems:
    if x.kind == s.kind and x.index == s.index: x = s
  for x in st.sourceOutputs.mitems:
    if x.kind == s.kind and x.index == s.index: x = s

proc startMock() =
  let st2 = @["front-left", "front-right"]
  proc v(l: float, r = -1.0): seq[int] = @[int(l * volumeNorm), int((if r < 0: l else: r) * volumeNorm)]
  proc dev(k: DeviceKind, i: int, name, desc: string, vol: seq[int], hw = true, monOf = "", ports: seq[Port] = @[],
           port = "", card = -1): Device =
    Device(kind: k, index: i, name: name, description: desc, channels: st2, volume: vol, baseVolume: volumeNorm,
           decibel: true, hardware: hw, monitorSource: (if k == dkSink: name & ".monitor" else: ""),
           monitorOfSink: monOf, ports: ports, activePort: port, card: card)
  proc app(k: DeviceKind, i, client, device: int, vol: seq[int], name, media: string, mute = false): Stream =
    Stream(kind: k, index: i, client: client, device: device, mute: mute, channels: st2, volume: vol,
           props: {"application.name": name, "media.name": media}.toTable)
  let speakers = @[Port(name: "analog-output-speaker", description: "Speakers", available: true, priority: 100),
                   Port(name: "analog-output-headphones", description: "Headphones", available: false, priority: 90)]
  state = State(loaded: true, defaultSink: "alsa_output.pci-0000_00_1f.3.analog-stereo",
                defaultSource: "alsa_input.usb-Blue_Yeti-00.analog-stereo")
  state.sinks = @[
    dev(dkSink, 0, "alsa_output.pci-0000_00_1f.3.analog-stereo", "Built-in Audio Analog Stereo", v(0.74),
        ports = speakers, port = "analog-output-speaker", card = 0),
    dev(dkSink, 1, "alsa_output.pci-0000_01_00.1.hdmi-stereo", "HDA NVidia Digital Stereo (HDMI)", v(1.0),
        ports = @[Port(name: "hdmi-output-0", description: "HDMI / DisplayPort", available: true, priority: 59)],
        port = "hdmi-output-0", card = 1),
    dev(dkSink, 2, "effect_input.eq", "Equalizer Sink", v(0.9), hw = false)]
  state.sources = @[
    dev(dkSource, 0, "alsa_input.usb-Blue_Yeti-00.analog-stereo", "Yeti Stereo Microphone", v(0.62),
        ports = @[Port(name: "analog-input-mic", description: "Microphone", available: true, priority: 85)],
        port = "analog-input-mic", card = 2),
    dev(dkSource, 1, "alsa_output.pci-0000_00_1f.3.analog-stereo.monitor", "Monitor of Built-in Audio Analog Stereo",
        v(1.0), monOf = "alsa_output.pci-0000_00_1f.3.analog-stereo")]
  state.sinkInputs = @[
    app(dkSink, 40, 12, 0, v(0.85), "Firefox", "Lofi beats to code to"),
    app(dkSink, 41, 13, 0, v(1.0, 0.7), "Spotify", "Spotify", mute = true),
    app(dkSink, 42, 14, 1, v(0.6), "Minecraft", "game audio")]
  state.sourceOutputs = @[app(dkSource, 50, 15, 0, v(1.0), "OBS Studio", "Mic/Aux")]
  proc prof(name, desc: string, prio: int, available = true): Profile =
    Profile(name: name, description: desc, priority: prio, available: available)
  state.cards = @[
    Card(index: 0, name: "alsa_card.pci-0000_00_1f.3", description: "Built-in Audio",
         activeProfile: "output:analog-stereo", profiles: @[
           prof("output:analog-stereo+input:analog-stereo", "Analog Stereo Duplex", 6565),
           prof("output:analog-stereo", "Analog Stereo Output", 6500),
           prof("output:analog-surround-51", "Analog Surround 5.1 Output", 1300, false),
           prof("off", "Off", 0)]),
    Card(index: 1, name: "alsa_card.pci-0000_01_00.1", description: "HDA NVidia",
         activeProfile: "output:hdmi-stereo",
         profiles: @[prof("output:hdmi-stereo", "Digital Stereo (HDMI) Output", 5900), prof("off", "Off", 0)]),
    Card(index: 2, name: "alsa_card.usb-Blue_Yeti-00", description: "Yeti Stereo Microphone",
         activeProfile: "input:analog-stereo",
         profiles: @[prof("input:analog-stereo", "Analog Stereo Input", 65), prof("off", "Off", 0)])]
  changed()

template mocked(body: untyped) =
  if mock:
    body
    changed()
    return

# --- The controls ---------------------------------------------------------------------------------------------

proc setVolume*(d: Device, v: seq[int]) =
  mocked:
    var x = d
    x.volume = v
    state.mockDevice(x)
  let name = d.name
  let n = d.volume.len
  run("vol-" & $d.kind & "-" & $d.index, proc (cb: SuccessCb, ud: pointer): ptr PaOperation =
    var cv = cvolume(v, n)
    if d.kind == dkSink: pa_context_set_sink_volume_by_name(ctx, name.cstring, addr cv, cb, ud)
    else: pa_context_set_source_volume_by_name(ctx, name.cstring, addr cv, cb, ud))

proc setMute*(d: Device, mute: bool) =
  mocked:
    var x = d
    x.mute = mute
    state.mockDevice(x)
  let name = d.name
  run("mute-" & $d.kind & "-" & $d.index, proc (cb: SuccessCb, ud: pointer): ptr PaOperation =
    if d.kind == dkSink: pa_context_set_sink_mute_by_name(ctx, name.cstring, mute.cint, cb, ud)
    else: pa_context_set_source_mute_by_name(ctx, name.cstring, mute.cint, cb, ud))

proc setDefault*(d: Device) =
  mocked:
    if d.kind == dkSink: state.defaultSink = d.name else: state.defaultSource = d.name
  let name = d.name
  run("default-" & $d.kind, proc (cb: SuccessCb, ud: pointer): ptr PaOperation =
    if d.kind == dkSink: pa_context_set_default_sink(ctx, name.cstring, cb, ud)
    else: pa_context_set_default_source(ctx, name.cstring, cb, ud))

proc setPort*(d: Device, port: string) =
  mocked:
    var x = d
    x.activePort = port
    state.mockDevice(x)
  let name = d.name
  run("port-" & $d.kind & "-" & $d.index, proc (cb: SuccessCb, ud: pointer): ptr PaOperation =
    if d.kind == dkSink: pa_context_set_sink_port_by_name(ctx, name.cstring, port.cstring, cb, ud)
    else: pa_context_set_source_port_by_name(ctx, name.cstring, port.cstring, cb, ud))

proc setLatencyOffset*(card, port: string, usec: int64) =
  if mock: return
  run("lat-" & card & "-" & port, proc (cb: SuccessCb, ud: pointer): ptr PaOperation =
    pa_context_set_port_latency_offset(ctx, card, port, usec, cb, ud))

proc setStreamVolume*(s: Stream, v: seq[int]) =
  mocked:
    var x = s
    x.volume = v
    state.mockStream(x)
  let idx = s.index.uint32
  let n = s.volume.len
  run("vol-" & $s.kind & "-stream-" & $s.index, proc (cb: SuccessCb, ud: pointer): ptr PaOperation =
    var cv = cvolume(v, n)
    if s.kind == dkSink: pa_context_set_sink_input_volume(ctx, idx, addr cv, cb, ud)
    else: pa_context_set_source_output_volume(ctx, idx, addr cv, cb, ud))

proc setStreamMute*(s: Stream, mute: bool) =
  mocked:
    var x = s
    x.mute = mute
    state.mockStream(x)
  let idx = s.index.uint32
  run("mute-" & $s.kind & "-stream-" & $s.index, proc (cb: SuccessCb, ud: pointer): ptr PaOperation =
    if s.kind == dkSink: pa_context_set_sink_input_mute(ctx, idx, mute.cint, cb, ud)
    else: pa_context_set_source_output_mute(ctx, idx, mute.cint, cb, ud))

proc moveStream*(s: Stream, target: Device) =
  mocked:
    var x = s
    x.device = target.index
    state.mockStream(x)
  let idx = s.index.uint32
  let name = target.name
  run("move-" & $s.kind & "-stream-" & $s.index, proc (cb: SuccessCb, ud: pointer): ptr PaOperation =
    if s.kind == dkSink: pa_context_move_sink_input_by_name(ctx, idx, name.cstring, cb, ud)
    else: pa_context_move_source_output_by_name(ctx, idx, name.cstring, cb, ud))

proc killStream*(s: Stream) =
  mocked:
    if s.kind == dkSink:
      for i, x in state.sinkInputs:
        if x.index == s.index:
          state.sinkInputs.delete i
          break
    else:
      for i, x in state.sourceOutputs:
        if x.index == s.index:
          state.sourceOutputs.delete i
          break
  let idx = s.index.uint32
  run("kill-" & $s.kind & "-stream-" & $s.index, proc (cb: SuccessCb, ud: pointer): ptr PaOperation =
    if s.kind == dkSink: pa_context_kill_sink_input(ctx, idx, cb, ud)
    else: pa_context_kill_source_output(ctx, idx, cb, ud))

proc setCardProfile*(c: Card, profile: string) =
  mocked:
    for x in state.cards.mitems:
      if x.index == c.index: x.activeProfile = profile
  let name = c.name
  run("profile-" & $c.index, proc (cb: SuccessCb, ud: pointer): ptr PaOperation =
    pa_context_set_card_profile_by_name(ctx, name.cstring, profile.cstring, cb, ud))

# --- Level meters -----------------------------------------------------------------------------------------------

type Meter = ref object
  source: string
  streamIndex: int             # a playback stream to follow, or -1 for the whole source
  onPeak: proc (peak: float)
  stream: ptr PaStreamC
  fake: Timer                  # the mock's

var
  meters: Table[int, Meter]
  nextMeter = 1

proc onRead(s: ptr PaStreamC, n: csize_t, ud: pointer) {.cdecl.} =
  var data: pointer
  var len: csize_t
  var peak = -1.0
  while pa_stream_peek(s, addr data, addr len) == 0 and len > 0:
    if data != nil:
      let f = cast[ptr UncheckedArray[float32]](data)
      for k in 0 ..< int(len div 4): peak = max(peak, abs(f[k].float))
    discard pa_stream_drop(s)
  let m = meters.getOrDefault(cast[int](ud))
  if m != nil and peak >= 0: m.onPeak(peak.clamp(0.0, 1.0))

proc openMeter(id: int, m: Meter) =
  ## A peak-detecting record stream, as pavucontrol does it: the server sends one float per 40 ms, not the audio.
  var ss = PaSampleSpec(format: PA_SAMPLE_FLOAT32LE, rate: 25, channels: 1)
  let p = pa_proplist_new()
  discard pa_proplist_sets(p, "application.id", meterAppId)
  discard pa_proplist_sets(p, "media.role", "abstract")
  discard pa_proplist_sets(p, "node.passive", "true")
  let s = pa_stream_new_with_proplist(ctx, "Peak detect", addr ss, nil, p)
  pa_proplist_free(p)
  if s == nil: return
  if m.streamIndex >= 0 and pa_stream_set_monitor_stream(s, m.streamIndex.uint32) < 0:
    pa_stream_unref(s)
    return
  pa_stream_set_read_callback(s, onRead, cast[pointer](id))
  var attr = PaBufferAttr(maxlength: PA_INVALID_INDEX, tlength: PA_INVALID_INDEX, prebuf: PA_INVALID_INDEX,
                          minreq: PA_INVALID_INDEX, fragsize: 4)
  if pa_stream_connect_record(s, m.source.cstring, addr attr,
                              PA_STREAM_DONT_MOVE or PA_STREAM_PEAK_DETECT or PA_STREAM_ADJUST_LATENCY) < 0:
    pa_stream_set_read_callback(s, nil, nil)
    pa_stream_unref(s)
    return
  m.stream = s

proc closeMeterStream(m: Meter) =
  if m.stream == nil: return
  pa_stream_set_read_callback(m.stream, nil, nil)
  discard pa_stream_disconnect(m.stream)
  pa_stream_unref(m.stream)
  m.stream = nil

proc meter*(source: string, streamIndex: int, onPeak: proc (peak: float)): int =
  ## Starts feeding `onPeak` with the peak level (0..1) of `source`, or of one playback stream on it. Returns an id
  ## for `stopMeter`.
  result = nextMeter
  inc nextMeter
  let m = Meter(source: source, streamIndex: streamIndex, onPeak: onPeak)
  meters[result] = m
  if mock:
    let phase = rand(6.0)
    let level = 0.3 + rand(0.5)
    var i = 0
    m.fake = every(40, proc () =
      inc i
      m.onPeak((level * (0.6 + 0.4 * sin(phase + i / 5)) + rand(0.08)).clamp(0.0, 1.0)))
  elif ready: openMeter(result, m)

proc stopMeter*(id: int) =
  let m = meters.getOrDefault(id)
  if m == nil: return
  meters.del id
  m.fake.cancel()
  closeMeterStream(m)

# --- Connection ---------------------------------------------------------------------------------------------------

proc connect()

proc teardown() =
  for m in meters.values: closeMeterStream(m)
  pa_context_set_state_callback(ctx, nil, nil)
  pa_context_set_subscribe_callback(ctx, nil, nil)
  pa_context_disconnect(ctx)
  pa_context_unref(ctx)
  ctx = nil
  ready = false
  refreshing = false
  dirty = false
  snap = nil
  pendingReq.clear()
  inFlight.clear()
  opKeys.clear()

proc failed() =
  ## No connection, or the server went away: say so and try again, as pavucontrol does.
  if ctx == nil: return
  let err = $pa_strerror(pa_context_errno(ctx))
  teardown()
  state = State(loaded: true, error: "Connection failure: " & err)
  changed()
  discard after(2000, connect)

proc onEvent(c: ptr PaContext, t: cint, idx: uint32, ud: pointer) {.cdecl.} = scheduleRefresh()

proc onState(c: ptr PaContext, ud: pointer) {.cdecl.} =
  if c != ctx: return
  case pa_context_get_state(c)
  of PA_CONTEXT_READY:
    ready = true
    pa_context_set_subscribe_callback(ctx, onEvent, nil)
    let op = pa_context_subscribe(ctx, PA_SUBSCRIPTION_MASK_ALL, nil, nil)
    if op != nil: pa_operation_unref(op)
    for id, m in meters: openMeter(id, m)
    refresh()
  of PA_CONTEXT_FAILED, PA_CONTEXT_TERMINATED:
    discard after(0, failed)   # not from inside libpulse's own dispatch
  else: discard

proc connect() =
  let p = pa_proplist_new()
  discard pa_proplist_sets(p, "application.id", "dev.v.volume")
  discard pa_proplist_sets(p, "application.icon_name", "multimedia-volume-control")
  ctx = pa_context_new_with_proplist(pa_glib_mainloop_get_api(mainloop), "Volume Control", p)
  pa_proplist_free(p)
  pa_context_set_state_callback(ctx, onState, nil)
  if pa_context_connect(ctx, nil, 0, nil) < 0: failed()

proc start*() =
  ## Connects (or, with PAVU_MOCK=1, makes up a server). Call once the UI is ready for `onChange`.
  if mock:
    startMock()
    return
  if mainloop == nil: mainloop = pa_glib_mainloop_new(nil)
  connect()
