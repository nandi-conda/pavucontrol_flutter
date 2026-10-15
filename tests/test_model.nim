import std/unittest
import ../src/model

suite "model":
  test "volumes":
    check @[65536, 32768].loudest == volumeNorm
    check @[65536, 32768].scaledTo(32768) == @[32768, 16384]
    check @[0, 0].scaledTo(100) == @[100, 100]
    check formatDb(volumeNorm) == "0.00 dB"
    check formatDb(0) == "-∞ dB"
    check formatPercent(32768) == "50%"

  test "names":
    check prettyChannel("front-left") == "Front Left"
    check prettyChannel("aux-thing") == "Aux Thing"
    check Port(description: "Speaker", available: false).label == "Speaker (unplugged)"
    check Device(kind: dkSink, name: "x").meterSource == "x.monitor"
    check Device(kind: dkSink, name: "x", monitorSource: "m").meterSource == "m"
    check Device(kind: dkSource, name: "mic").meterSource == "mic"
