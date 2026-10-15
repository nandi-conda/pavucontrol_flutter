## Volume Control: a pavucontrol clone on nimkit (webby's Nim UI framework), talking to PulseAudio / PipeWire
## through libpulse (pulse.nim). Five tabs: Playback, Recording, Output Devices, Input Devices, Configuration.
##
## The list of the current tab is a column of tiles, one per stream, device or card. When the server's state
## changes, tiles still there are updated in place (so a slider being dragged and its meter keep going), gone ones
## removed and new ones added; switching tab or filter builds the list afresh.

import std/[math, strutils, tables, times]
import prgname   # before nimkit, which starts GTK
import nimkit
import model, pulse

nimkit.appName = "volume"

proc gtk_window_set_default_icon_name(name: cstring) {.importc, cdecl.}

type
  Tab = enum tPlayback, tRecording, tOutput, tInput, tConfig

  StreamFilter = enum sfAll, sfApplications, sfVirtual
  DeviceFilter = enum dfAll, dfAllExceptMonitors, dfHardware, dfVirtual, dfMonitors

  ## The slider(s) of one device or stream: one for all channels while locked, else one per channel.
  Volumes = ref object
    box: Widget
    sliders, percents, dbs: seq[Widget]
    channels: seq[string]
    values: seq[int]
    locked, showDb: bool
    baseVolume: int
    userUntil: float          # until then the server's values don't move the sliders (they lag the user's)
    onChange: proc (v: seq[int])

  Tile = ref object
    root: Widget
    update: proc (): bool     # takes the tile's item from `state` again; false: it can't, build it anew
    close: proc ()            # stops its meter

const
  pctWidth = 52
  dbWidth = 84
  labelWidth = 96

var
  tab = tPlayback
  playbackFilter = sfApplications
  recordingFilter = sfApplications
  outputFilter = dfAll
  inputFilter = dfAllExceptMonitors
  tiles: OrderedTable[string, Tile]
  tabButtons: array[Tab, Widget]
  list = column()
  footer = column()
  messageText = label("")
  message = column(messageText)   # in the list when it has nothing else to show

# ---------------------------------------------------------------------------------------------------------------
# Volume sliders and level meters

proc marks(v: Volumes, max: int): seq[(float, string)] =
  result.add (0.0, "Silence")
  if v.baseVolume > 0 and v.baseVolume != volumeNorm and v.baseVolume < max: result.add (v.baseVolume.float, "Base")
  result.add (volumeNorm.float, if v.showDb: "100% (0 dB)" else: "100%")

proc showValues(v: Volumes) =
  let shown = if v.locked: @[v.values.loudest] else: v.values
  for i, s in v.sliders:
    let x = shown[i]
    let top = max(volumeUiMax, x)
    s.setRange(0, top.float, volumeNorm * 0.05)
    s.marks = v.marks(top)
    s.value = x.float
    v.percents[i].text = formatPercent(x)
    if v.showDb: v.dbs[i].text = formatDb(x)

proc channelSlider(v: Volumes, ch: int): Widget =
  ## The slider for channel `ch`, or for all of them while locked.
  slider(onValue = proc (x: float) =
    let x = int(round(x))
    if v.locked: v.values = v.values.scaledTo(x)
    else: v.values[ch] = x
    v.userUntil = epochTime() + 0.5
    v.showValues()
    v.onChange(v.values))

proc build(v: Volumes) =
  v.box.clear()
  v.sliders.setLen 0
  v.percents.setLen 0
  v.dbs.setLen 0
  let n = if v.locked: 1 else: v.values.len
  for i in 0 ..< n:
    let s = v.channelSlider(i)
    let r = row()
    if not v.locked: r.add label(prettyChannel(v.channels[i])).sized(labelWidth)
    r.add s.expand
    let pct = label("").sized(pctWidth)
    r.add pct
    v.sliders.add s
    v.percents.add pct
    if v.showDb:
      let db = label("").sized(dbWidth)
      r.add db
      v.dbs.add db
    v.box.add r
  v.showValues()

proc newVolumes(channels: seq[string], values: seq[int], baseVolume: int, showDb: bool,
                onChange: proc (v: seq[int])): Volumes =
  result = Volumes(box: column(), channels: channels, values: values, locked: true, showDb: showDb,
                   baseVolume: baseVolume, onChange: onChange)
  result.box.spacing = 0
  result.build()

proc update(v: Volumes, values: seq[int], baseVolume: int) =
  if epochTime() < v.userUntil: return
  v.baseVolume = baseVolume
  if values != v.values:
    v.values = values
    v.showValues()

proc setLocked(v: Volumes, locked: bool) =
  if locked == v.locked: return
  v.locked = locked
  v.build()

type Level = ref object
  bar: Widget
  id: int
  shown: float

proc newLevel(source: string, streamIndex: int, trailing: int): (Widget, Level) =
  ## A level meter under the sliders, as wide as their track.
  let l = Level(bar: progress())
  l.id = meter(source, streamIndex, proc (peak: float) =
    # The sliders' cubic scale, falling back slowly as pavucontrol's does.
    let v = cbrt(peak)
    l.shown = if v >= l.shown: v else: max(v, l.shown - 0.04)
    l.bar.value = l.shown)
  let r = row(l.bar.expand)
  if trailing > 0: r.add label("").sized(trailing)
  (r, l)

# ---------------------------------------------------------------------------------------------------------------
# Tiles

proc header(): Widget =
  result = row()
  result.spacing = 6

proc streamTile(kind: DeviceKind, index: int): Tile =
  proc find(): ptr Stream =
    if kind == dkSink:
      for s in state.sinkInputs.mitems:
        if s.index == index: return addr s
    else:
      for s in state.sourceOutputs.mitems:
        if s.index == index: return addr s
  proc devices(): seq[Device] = (if kind == dkSink: state.sinks else: state.sources)
  let s0 = find()[]
  let heading = label(s0.title)
  let mute = toggle("Mute", s0.mute, proc (on: bool) = setStreamMute(find()[], on))
  let target = dropdown(onSelect = proc (i: int) =
    let ds = devices()
    if i < ds.len: moveStream(find()[], ds[i]))
  let volumes = newVolumes(s0.channels, s0.volume, volumeNorm, showDb = true,
                           onChange = proc (v: seq[int]) = setStreamVolume(find()[], v))
  let lock = toggle("Lock", true, proc (on: bool) = volumes.setLocked(on))
  let top = header()
  top.add heading.expand
  top.add label(if kind == dkSink: "on" else: "from")
  top.add target
  top.add mute
  if s0.volume.len > 1: top.add lock
  top.add button("Terminate", proc () = killStream(find()[]))
  let root = column(top)
  root.padding = 10
  root.spacing = 4
  if s0.hasVolume: root.add volumes.box
  var level: Level
  var shownDevice = -2
  proc showTarget(s: Stream) =
    var names: seq[string]
    var at = -1
    for i, d in devices():
      names.add d.description
      if d.index == s.device: at = i
    target.items = names
    target.selected = at
    if s.device == shownDevice: return
    # The meter follows the stream's device (a playback stream's own level, on its sink's monitor).
    shownDevice = s.device
    if level != nil:
      stopMeter(level.id)
      root.remove(root.children[^1])
      level = nil
    for d in devices():
      if d.index == s.device:
        let (w, l) = newLevel(d.meterSource, (if kind == dkSink: s.index else: -1), pctWidth + dbWidth + 16)
        root.add w
        level = l
  showTarget(s0)
  Tile(root: root,
    update: proc (): bool =
      let s = find()
      if s == nil or s.volume.len != volumes.values.len: return false
      heading.text = s[].title
      mute.checked = s.mute
      volumes.update(s.volume, volumeNorm)
      showTarget(s[])
      true,
    close: proc () =
      if level != nil: stopMeter(level.id))

proc deviceTile(kind: DeviceKind, index: int): Tile =
  proc find(): ptr Device =
    if kind == dkSink:
      for d in state.sinks.mitems:
        if d.index == index: return addr d
    else:
      for d in state.sources.mitems:
        if d.index == index: return addr d
  proc isDefault(d: Device): bool = d.name == (if kind == dkSink: state.defaultSink else: state.defaultSource)
  let d0 = find()[]
  let heading = label(d0.description)
  let mute = toggle("Mute", d0.mute, proc (on: bool) = setMute(find()[], on))
  var fallback: Widget
  fallback = toggle("Default", isDefault(d0), proc (on: bool) =
    if on: setDefault(find()[])
    else: fallback.checked = true)   # the default only changes by picking another one
  let volumes = newVolumes(d0.channels, d0.volume, d0.baseVolume, showDb = d0.decibel,
                           onChange = proc (v: seq[int]) = setVolume(find()[], v))
  let lock = toggle("Lock", true, proc (on: bool) = volumes.setLocked(on))
  let top = header()
  top.add heading.expand
  top.add mute
  if d0.volume.len > 1: top.add lock
  top.add fallback
  let root = column(top)
  root.padding = 10
  root.spacing = 4
  let port = dropdown(onSelect = proc (i: int) =
    let d = find()[]
    if i < d.ports.len: setPort(d, d.ports[i].name))
  let portCount = d0.ports.len
  if portCount > 0: root.add row(label("Port:"), port)
  root.add volumes.box
  let (meterRow, level) = newLevel(d0.meterSource, -1, pctWidth + (if d0.decibel: dbWidth + 8 else: 0) + 8)
  root.add meterRow

  # Advanced: the active port's latency offset, and the device's name.
  let advancedBox = column()
  var latency: Widget
  proc offsetMs(d: Device): string =
    let card = state.cardFor(d)
    if card != nil:
      for p in card.ports:
        if p.name == d.activePort: return formatFloat(p.latencyOffsetUsec.float / 1000, ffDecimal, 2)
    "0.00"
  proc commitLatency(text: string) =
    let d = find()[]
    let card = state.cardFor(d)
    if card == nil or d.activePort.len == 0: return
    try: setLatencyOffset(card.name, d.activePort, int64(round(parseFloat(text.strip) * 1000)))
    except ValueError: discard
  let advanced = toggle("Advanced", false, proc (on: bool) =
    advancedBox.clear()
    latency = nil
    if not on: return
    let d = find()[]
    latency = entry(text = offsetMs(d), onSubmit = commitLatency).sized(90)
    latency.enabled = state.cardFor(d) != nil and d.activePort.len > 0
    advancedBox.add row(label("Latency offset:"), latency, label("ms (Enter applies)"))
    advancedBox.add label((if kind == dkSink: "Sink: " else: "Source: ") & d.name))
  root.add row(advanced)
  root.add advancedBox

  proc showPorts(d: Device) =
    var names: seq[string]
    var at = -1
    for i, p in d.ports:
      names.add p.label
      if p.name == d.activePort: at = i
    port.items = names
    port.selected = at
  showPorts(d0)
  Tile(root: root,
    update: proc (): bool =
      let d = find()
      if d == nil or d.volume.len != volumes.values.len or d.ports.len != portCount or
         d.decibel != volumes.showDb: return false
      heading.text = d.description
      mute.checked = d.mute
      fallback.checked = isDefault(d[])
      volumes.update(d.volume, d.baseVolume)
      showPorts(d[])
      true,
    close: proc () = stopMeter(level.id))

proc cardTile(index: int): Tile =
  proc find(): ptr Card =
    for c in state.cards.mitems:
      if c.index == index: return addr c
  let heading = label(find().description)
  let profile = dropdown(onSelect = proc (i: int) =
    let c = find()[]
    if i < c.profiles.len: setCardProfile(c, c.profiles[i].name))
  let root = column(heading, row(label("Profile:"), profile.expand))
  root.padding = 10
  proc show(c: Card) =
    heading.text = c.description
    var names: seq[string]
    var at = -1
    for i, p in c.profiles:
      names.add p.label
      if p.name == c.activeProfile: at = i
    profile.items = names
    profile.selected = at
  show(find()[])
  Tile(root: root,
    update: proc (): bool =
      let c = find()
      if c == nil: return false
      show(c[])
      true,
    close: proc () = discard)

# ---------------------------------------------------------------------------------------------------------------
# The list

proc ok(s: Stream, f: StreamFilter): bool =
  case f
  of sfAll: true
  of sfApplications: not s.isVirtual
  of sfVirtual: s.isVirtual

proc ok(d: Device, f: DeviceFilter): bool =
  case f
  of dfAll: true
  of dfAllExceptMonitors: not d.isMonitor
  of dfHardware: d.hardware and not d.isMonitor
  of dfVirtual: not d.hardware and not d.isMonitor
  of dfMonitors: d.isMonitor

type Item = tuple[key: string, kind: Tab, index: int]

proc wanted(): seq[Item] =
  ## The items the current tab shows, each with a key for its tile.
  case tab
  of tPlayback:
    for s in state.sinkInputs:
      if s.ok(playbackFilter): result.add ("si" & $s.index, tab, s.index)
  of tRecording:
    for s in state.sourceOutputs:
      if s.ok(recordingFilter): result.add ("so" & $s.index, tab, s.index)
  of tOutput:
    for d in state.sinks:
      if d.ok(outputFilter): result.add ("sink" & $d.index, tab, d.index)
  of tInput:
    for d in state.sources:
      if d.ok(inputFilter): result.add ("source" & $d.index, tab, d.index)
  of tConfig:
    for c in state.cards: result.add ("card" & $c.index, tab, c.index)

proc makeTile(it: Item): Tile =
  case it.kind
  of tPlayback: streamTile(dkSink, it.index)
  of tRecording: streamTile(dkSource, it.index)
  of tOutput: deviceTile(dkSink, it.index)
  of tInput: deviceTile(dkSource, it.index)
  of tConfig: cardTile(it.index)

proc emptyText(): string =
  case tab
  of tPlayback: "No application is currently playing audio."
  of tRecording: "No application is currently recording audio."
  of tOutput: "No output devices available"
  of tInput: "No input devices available"
  of tConfig: "No cards available for configuration"

proc closeAll() =
  for t in tiles.values: t.close()
  tiles.clear()
  list.clear()

proc showMessage(text: string) =
  messageText.text = text
  if message.parent == nil: list.add message

proc sync() =
  ## Brings the list in line with `state`.
  if not state.loaded or state.error.len > 0:
    closeAll()
    showMessage(if state.loaded: state.error else: "Establishing connection to PulseAudio. Please wait...")
    return
  let want = wanted()
  var keys: seq[string]
  for it in want: keys.add it.key
  var rebuild = false
  for k, t in tiles:
    if k notin keys or not t.update():
      rebuild = true
      break
  if rebuild: closeAll()
  if message.parent != nil: list.remove(message)
  for it in want:
    if it.key notin tiles:
      let t = makeTile(it)
      tiles[it.key] = t
      list.add t.root
  if tiles.len == 0: showMessage(emptyText())

proc rebuild() =
  closeAll()
  sync()

# ---------------------------------------------------------------------------------------------------------------
# Tabs and the "Show:" filter

proc buildFooter() =
  footer.clear()
  if tab == tConfig: return
  proc picker[T: enum](current: T, choices: openArray[(T, string)], pick: proc (v: T)): Widget =
    var names: seq[string]
    var values: seq[T]
    var at = 0
    for i, (value, name) in choices:
      names.add name
      values.add value
      if value == current: at = i
    dropdown(names, at, proc (i: int) =
      pick(values[i])
      rebuild())
  const streams = [(sfAll, "All Streams"), (sfApplications, "Applications"), (sfVirtual, "Virtual Streams")]
  let dd = case tab
    of tPlayback: picker(playbackFilter, streams, proc (v: StreamFilter) = playbackFilter = v)
    of tRecording: picker(recordingFilter, streams, proc (v: StreamFilter) = recordingFilter = v)
    of tOutput:
      picker(outputFilter, [(dfAll, "All Output Devices"), (dfHardware, "Hardware Output Devices"),
                            (dfVirtual, "Virtual Output Devices")], proc (v: DeviceFilter) = outputFilter = v)
    else:
      picker(inputFilter, [(dfAll, "All Input Devices"), (dfAllExceptMonitors, "All Except Monitors"),
                           (dfHardware, "Hardware Input Devices"), (dfVirtual, "Virtual Input Devices"),
                           (dfMonitors, "Monitors")], proc (v: DeviceFilter) = inputFilter = v)
  let r = row(label("").expand, label("Show:"), dd)
  r.padding = 8
  footer.add r

proc selectTab(t: Tab) =
  tab = t
  for x, b in tabButtons: b.checked = x == t
  buildFooter()
  rebuild()

const tabNames: array[Tab, string] = ["Playback", "Recording", "Output Devices", "Input Devices", "Configuration"]

let tabRow = row()
tabRow.padding = 6
tabRow.spacing = 4
proc tabButton(t: Tab): Widget = toggle(tabNames[t], t == tab, proc (on: bool) = selectTab(t))

for t in Tab:
  tabButtons[t] = tabButton(t)
  tabRow.add tabButtons[t]

list.spacing = 0
message.padding = 12
footer.spacing = 0
buildFooter()
sync()
pulse.onChange = sync
pulse.start()
gtk_window_set_default_icon_name("dev.v.volume")
run("Volume Control", column(tabRow, scroll(list).expand, footer), 760, 560)
