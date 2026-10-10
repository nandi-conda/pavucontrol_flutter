// Minimal dart:ffi bindings for the parts of libpulse's asynchronous API we use.
// Layouts mirror <pulse/introspect.h>, <pulse/volume.h> etc.; libpulse only ever appends
// fields to these structs, so reading the leading fields is stable across versions.
// ignore_for_file: camel_case_types, non_constant_identifier_names

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const paChannelsMax = 32;
const paInvalidIndex = 0xffffffff;

// pa_context_state_t
const paContextReady = 4;
const paContextFailed = 5;
const paContextTerminated = 6;

const paSubscriptionMaskAll = 0x02ff;

const paSampleFloat32le = 5;

// pa_stream_flags_t
const paStreamDontMove = 0x0200;
const paStreamPeakDetect = 0x0800;
const paStreamAdjustLatency = 0x2000;

// pa_sink_flags_t / pa_source_flags_t (same bits)
const paDeviceHardware = 0x0004;
const paDeviceDecibelVolume = 0x0020;

const paPortAvailableNo = 1;

final class pa_sample_spec extends Struct {
  @Int32()
  external int format;
  @Uint32()
  external int rate;
  @Uint8()
  external int channels;
}

final class pa_channel_map extends Struct {
  @Uint8()
  external int channels;
  @Array(paChannelsMax)
  external Array<Int32> map;
}

final class pa_cvolume extends Struct {
  @Uint8()
  external int channels;
  @Array(paChannelsMax)
  external Array<Uint32> values;
}

final class pa_buffer_attr extends Struct {
  @Uint32()
  external int maxlength;
  @Uint32()
  external int tlength;
  @Uint32()
  external int prebuf;
  @Uint32()
  external int minreq;
  @Uint32()
  external int fragsize;
}

final class pa_port_info extends Struct {
  // pa_sink_port_info and pa_source_port_info share this layout.
  external Pointer<Utf8> name;
  external Pointer<Utf8> description;
  @Uint32()
  external int priority;
  @Int32()
  external int available;
}

final class pa_device_info extends Struct {
  // pa_sink_info and pa_source_info share this layout (monitor_source <-> monitor_of_sink).
  external Pointer<Utf8> name;
  @Uint32()
  external int index;
  external Pointer<Utf8> description;
  external pa_sample_spec sample_spec;
  external pa_channel_map channel_map;
  @Uint32()
  external int owner_module;
  external pa_cvolume volume;
  @Int32()
  external int mute;
  @Uint32()
  external int monitor_index;
  external Pointer<Utf8> monitor_name;
  @Uint64()
  external int latency;
  external Pointer<Utf8> driver;
  @Uint32()
  external int flags;
  external Pointer<Void> proplist;
  @Uint64()
  external int configured_latency;
  @Uint32()
  external int base_volume;
  @Int32()
  external int state;
  @Uint32()
  external int n_volume_steps;
  @Uint32()
  external int card;
  @Uint32()
  external int n_ports;
  external Pointer<Pointer<pa_port_info>> ports;
  external Pointer<pa_port_info> active_port;
}

final class pa_sink_input_info extends Struct {
  @Uint32()
  external int index;
  external Pointer<Utf8> name;
  @Uint32()
  external int owner_module;
  @Uint32()
  external int client;
  @Uint32()
  external int sink;
  external pa_sample_spec sample_spec;
  external pa_channel_map channel_map;
  external pa_cvolume volume;
  @Uint64()
  external int buffer_usec;
  @Uint64()
  external int sink_usec;
  external Pointer<Utf8> resample_method;
  external Pointer<Utf8> driver;
  @Int32()
  external int mute;
  external Pointer<Void> proplist;
  @Int32()
  external int corked;
  @Int32()
  external int has_volume;
}

final class pa_source_output_info extends Struct {
  @Uint32()
  external int index;
  external Pointer<Utf8> name;
  @Uint32()
  external int owner_module;
  @Uint32()
  external int client;
  @Uint32()
  external int source;
  external pa_sample_spec sample_spec;
  external pa_channel_map channel_map;
  @Uint64()
  external int buffer_usec;
  @Uint64()
  external int source_usec;
  external Pointer<Utf8> resample_method;
  external Pointer<Utf8> driver;
  external Pointer<Void> proplist;
  @Int32()
  external int corked;
  external pa_cvolume volume;
  @Int32()
  external int mute;
  @Int32()
  external int has_volume;
}

final class pa_card_profile_info2 extends Struct {
  external Pointer<Utf8> name;
  external Pointer<Utf8> description;
  @Uint32()
  external int n_sinks;
  @Uint32()
  external int n_sources;
  @Uint32()
  external int priority;
  @Int32()
  external int available;
}

final class pa_card_port_info extends Struct {
  external Pointer<Utf8> name;
  external Pointer<Utf8> description;
  @Uint32()
  external int priority;
  @Int32()
  external int available;
  @Int32()
  external int direction;
  @Uint32()
  external int n_profiles;
  external Pointer<Void> profiles;
  external Pointer<Void> proplist;
  @Int64()
  external int latency_offset;
}

final class pa_card_info extends Struct {
  @Uint32()
  external int index;
  external Pointer<Utf8> name;
  @Uint32()
  external int owner_module;
  external Pointer<Utf8> driver;
  @Uint32()
  external int n_profiles;
  external Pointer<Void> profiles;
  external Pointer<Void> active_profile;
  external Pointer<Void> proplist;
  @Uint32()
  external int n_ports;
  external Pointer<Pointer<pa_card_port_info>> ports;
  external Pointer<Pointer<pa_card_profile_info2>> profiles2;
  external Pointer<pa_card_profile_info2> active_profile2;
}

final class pa_server_info extends Struct {
  external Pointer<Utf8> user_name;
  external Pointer<Utf8> host_name;
  external Pointer<Utf8> server_version;
  external Pointer<Utf8> server_name;
  external pa_sample_spec sample_spec;
  external Pointer<Utf8> default_sink_name;
  external Pointer<Utf8> default_source_name;
}

// Callback signatures.
typedef pa_context_notify_cb = Void Function(Pointer<Void> c, Pointer<Void> userdata);
typedef pa_context_success_cb = Void Function(Pointer<Void> c, Int32 success, Pointer<Void> userdata);
typedef pa_context_subscribe_cb = Void Function(Pointer<Void> c, Uint32 t, Uint32 idx, Pointer<Void> userdata);
typedef pa_device_info_cb = Void Function(
  Pointer<Void> c,
  Pointer<pa_device_info> i,
  Int32 eol,
  Pointer<Void> userdata,
);
typedef pa_sink_input_info_cb = Void Function(
  Pointer<Void> c,
  Pointer<pa_sink_input_info> i,
  Int32 eol,
  Pointer<Void> userdata,
);
typedef pa_source_output_info_cb = Void Function(
  Pointer<Void> c,
  Pointer<pa_source_output_info> i,
  Int32 eol,
  Pointer<Void> userdata,
);
typedef pa_card_info_cb = Void Function(Pointer<Void> c, Pointer<pa_card_info> i, Int32 eol, Pointer<Void> userdata);
typedef pa_server_info_cb = Void Function(Pointer<Void> c, Pointer<pa_server_info> i, Pointer<Void> userdata);
typedef pa_stream_notify_cb = Void Function(Pointer<Void> s, Pointer<Void> userdata);
typedef pa_stream_request_cb = Void Function(Pointer<Void> s, Size nbytes, Pointer<Void> userdata);

typedef PaOp = Pointer<Void>;
typedef PaCtx = Pointer<Void>;
typedef PaUd = Pointer<Void>;
typedef PaStr = Pointer<Utf8>;
typedef PaSuccessCb = Pointer<NativeFunction<pa_context_success_cb>>;

/// libpulse.so.0, looked up the way the dynamic linker would, then next to a conda/pixi
/// install of this app (`$PREFIX/lib/pavucontrol_flutter/<exe>` -> `$PREFIX/lib`).
DynamicLibrary openLibpulse() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final candidates = ['libpulse.so.0', '$exeDir/../libpulse.so.0', '$exeDir/lib/libpulse.so.0'];
  Object? firstError;
  for (final c in candidates) {
    try {
      return DynamicLibrary.open(c);
    } catch (e) {
      firstError ??= e;
    }
  }
  throw firstError!;
}

class LibPulse {
  LibPulse(DynamicLibrary l)
    : mainloop_new = l.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('pa_mainloop_new'),
      mainloop_free = l.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('pa_mainloop_free'),
      mainloop_get_api = l.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>(
        'pa_mainloop_get_api',
      ),
      mainloop_iterate = l
          .lookupFunction<
            Int32 Function(Pointer<Void>, Int32, Pointer<Int32>),
            int Function(Pointer<Void>, int, Pointer<Int32>)
          >('pa_mainloop_iterate'),
      proplist_new = l.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('pa_proplist_new'),
      proplist_free = l.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('pa_proplist_free'),
      proplist_sets = l
          .lookupFunction<Int32 Function(Pointer<Void>, PaStr, PaStr), int Function(Pointer<Void>, PaStr, PaStr)>(
            'pa_proplist_sets',
          ),
      proplist_gets = l.lookupFunction<PaStr Function(Pointer<Void>, PaStr), PaStr Function(Pointer<Void>, PaStr)>(
        'pa_proplist_gets',
      ),
      proplist_iterate = l
          .lookupFunction<
            PaStr Function(Pointer<Void>, Pointer<Pointer<Void>>),
            PaStr Function(Pointer<Void>, Pointer<Pointer<Void>>)
          >('pa_proplist_iterate'),
      channel_position_to_string = l.lookupFunction<PaStr Function(Int32), PaStr Function(int)>(
        'pa_channel_position_to_string',
      ),
      strerror = l.lookupFunction<PaStr Function(Int32), PaStr Function(int)>('pa_strerror'),
      operation_unref = l.lookupFunction<Void Function(PaOp), void Function(PaOp)>('pa_operation_unref'),
      context_new_with_proplist = l
          .lookupFunction<
            PaCtx Function(Pointer<Void>, PaStr, Pointer<Void>),
            PaCtx Function(Pointer<Void>, PaStr, Pointer<Void>)
          >('pa_context_new_with_proplist'),
      context_unref = l.lookupFunction<Void Function(PaCtx), void Function(PaCtx)>('pa_context_unref'),
      context_connect = l
          .lookupFunction<
            Int32 Function(PaCtx, PaStr, Int32, Pointer<Void>),
            int Function(PaCtx, PaStr, int, Pointer<Void>)
          >('pa_context_connect'),
      context_disconnect = l.lookupFunction<Void Function(PaCtx), void Function(PaCtx)>('pa_context_disconnect'),
      context_get_state = l.lookupFunction<Int32 Function(PaCtx), int Function(PaCtx)>('pa_context_get_state'),
      context_errno = l.lookupFunction<Int32 Function(PaCtx), int Function(PaCtx)>('pa_context_errno'),
      context_set_state_callback = l
          .lookupFunction<
            Void Function(PaCtx, Pointer<NativeFunction<pa_context_notify_cb>>, PaUd),
            void Function(PaCtx, Pointer<NativeFunction<pa_context_notify_cb>>, PaUd)
          >('pa_context_set_state_callback'),
      context_set_subscribe_callback = l
          .lookupFunction<
            Void Function(PaCtx, Pointer<NativeFunction<pa_context_subscribe_cb>>, PaUd),
            void Function(PaCtx, Pointer<NativeFunction<pa_context_subscribe_cb>>, PaUd)
          >('pa_context_set_subscribe_callback'),
      context_subscribe = l
          .lookupFunction<
            PaOp Function(PaCtx, Uint32, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, int, PaSuccessCb, PaUd)
          >('pa_context_subscribe'),
      get_sink_info_list = l
          .lookupFunction<
            PaOp Function(PaCtx, Pointer<NativeFunction<pa_device_info_cb>>, PaUd),
            PaOp Function(PaCtx, Pointer<NativeFunction<pa_device_info_cb>>, PaUd)
          >('pa_context_get_sink_info_list'),
      get_source_info_list = l
          .lookupFunction<
            PaOp Function(PaCtx, Pointer<NativeFunction<pa_device_info_cb>>, PaUd),
            PaOp Function(PaCtx, Pointer<NativeFunction<pa_device_info_cb>>, PaUd)
          >('pa_context_get_source_info_list'),
      get_sink_input_info_list = l
          .lookupFunction<
            PaOp Function(PaCtx, Pointer<NativeFunction<pa_sink_input_info_cb>>, PaUd),
            PaOp Function(PaCtx, Pointer<NativeFunction<pa_sink_input_info_cb>>, PaUd)
          >('pa_context_get_sink_input_info_list'),
      get_source_output_info_list = l
          .lookupFunction<
            PaOp Function(PaCtx, Pointer<NativeFunction<pa_source_output_info_cb>>, PaUd),
            PaOp Function(PaCtx, Pointer<NativeFunction<pa_source_output_info_cb>>, PaUd)
          >('pa_context_get_source_output_info_list'),
      get_card_info_list = l
          .lookupFunction<
            PaOp Function(PaCtx, Pointer<NativeFunction<pa_card_info_cb>>, PaUd),
            PaOp Function(PaCtx, Pointer<NativeFunction<pa_card_info_cb>>, PaUd)
          >('pa_context_get_card_info_list'),
      get_server_info = l
          .lookupFunction<
            PaOp Function(PaCtx, Pointer<NativeFunction<pa_server_info_cb>>, PaUd),
            PaOp Function(PaCtx, Pointer<NativeFunction<pa_server_info_cb>>, PaUd)
          >('pa_context_get_server_info'),
      set_sink_volume_by_name = l
          .lookupFunction<
            PaOp Function(PaCtx, PaStr, Pointer<pa_cvolume>, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, PaStr, Pointer<pa_cvolume>, PaSuccessCb, PaUd)
          >('pa_context_set_sink_volume_by_name'),
      set_source_volume_by_name = l
          .lookupFunction<
            PaOp Function(PaCtx, PaStr, Pointer<pa_cvolume>, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, PaStr, Pointer<pa_cvolume>, PaSuccessCb, PaUd)
          >('pa_context_set_source_volume_by_name'),
      set_sink_mute_by_name = l
          .lookupFunction<
            PaOp Function(PaCtx, PaStr, Int32, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, PaStr, int, PaSuccessCb, PaUd)
          >('pa_context_set_sink_mute_by_name'),
      set_source_mute_by_name = l
          .lookupFunction<
            PaOp Function(PaCtx, PaStr, Int32, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, PaStr, int, PaSuccessCb, PaUd)
          >('pa_context_set_source_mute_by_name'),
      set_default_sink = l
          .lookupFunction<
            PaOp Function(PaCtx, PaStr, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, PaStr, PaSuccessCb, PaUd)
          >('pa_context_set_default_sink'),
      set_default_source = l
          .lookupFunction<
            PaOp Function(PaCtx, PaStr, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, PaStr, PaSuccessCb, PaUd)
          >('pa_context_set_default_source'),
      set_sink_port_by_name = l
          .lookupFunction<
            PaOp Function(PaCtx, PaStr, PaStr, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, PaStr, PaStr, PaSuccessCb, PaUd)
          >('pa_context_set_sink_port_by_name'),
      set_source_port_by_name = l
          .lookupFunction<
            PaOp Function(PaCtx, PaStr, PaStr, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, PaStr, PaStr, PaSuccessCb, PaUd)
          >('pa_context_set_source_port_by_name'),
      set_port_latency_offset = l
          .lookupFunction<
            PaOp Function(PaCtx, PaStr, PaStr, Int64, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, PaStr, PaStr, int, PaSuccessCb, PaUd)
          >('pa_context_set_port_latency_offset'),
      set_sink_input_volume = l
          .lookupFunction<
            PaOp Function(PaCtx, Uint32, Pointer<pa_cvolume>, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, int, Pointer<pa_cvolume>, PaSuccessCb, PaUd)
          >('pa_context_set_sink_input_volume'),
      set_source_output_volume = l
          .lookupFunction<
            PaOp Function(PaCtx, Uint32, Pointer<pa_cvolume>, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, int, Pointer<pa_cvolume>, PaSuccessCb, PaUd)
          >('pa_context_set_source_output_volume'),
      set_sink_input_mute = l
          .lookupFunction<
            PaOp Function(PaCtx, Uint32, Int32, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, int, int, PaSuccessCb, PaUd)
          >('pa_context_set_sink_input_mute'),
      set_source_output_mute = l
          .lookupFunction<
            PaOp Function(PaCtx, Uint32, Int32, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, int, int, PaSuccessCb, PaUd)
          >('pa_context_set_source_output_mute'),
      move_sink_input_by_name = l
          .lookupFunction<
            PaOp Function(PaCtx, Uint32, PaStr, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, int, PaStr, PaSuccessCb, PaUd)
          >('pa_context_move_sink_input_by_name'),
      move_source_output_by_name = l
          .lookupFunction<
            PaOp Function(PaCtx, Uint32, PaStr, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, int, PaStr, PaSuccessCb, PaUd)
          >('pa_context_move_source_output_by_name'),
      kill_sink_input = l
          .lookupFunction<
            PaOp Function(PaCtx, Uint32, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, int, PaSuccessCb, PaUd)
          >('pa_context_kill_sink_input'),
      kill_source_output = l
          .lookupFunction<
            PaOp Function(PaCtx, Uint32, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, int, PaSuccessCb, PaUd)
          >('pa_context_kill_source_output'),
      set_card_profile_by_name = l
          .lookupFunction<
            PaOp Function(PaCtx, PaStr, PaStr, PaSuccessCb, PaUd),
            PaOp Function(PaCtx, PaStr, PaStr, PaSuccessCb, PaUd)
          >('pa_context_set_card_profile_by_name'),
      stream_new_with_proplist = l
          .lookupFunction<
            Pointer<Void> Function(PaCtx, PaStr, Pointer<pa_sample_spec>, Pointer<Void>, Pointer<Void>),
            Pointer<Void> Function(PaCtx, PaStr, Pointer<pa_sample_spec>, Pointer<Void>, Pointer<Void>)
          >('pa_stream_new_with_proplist'),
      stream_unref = l.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('pa_stream_unref'),
      stream_set_monitor_stream = l
          .lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>(
            'pa_stream_set_monitor_stream',
          ),
      stream_set_read_callback = l
          .lookupFunction<
            Void Function(Pointer<Void>, Pointer<NativeFunction<pa_stream_request_cb>>, PaUd),
            void Function(Pointer<Void>, Pointer<NativeFunction<pa_stream_request_cb>>, PaUd)
          >('pa_stream_set_read_callback'),
      stream_connect_record = l
          .lookupFunction<
            Int32 Function(Pointer<Void>, PaStr, Pointer<pa_buffer_attr>, Int32),
            int Function(Pointer<Void>, PaStr, Pointer<pa_buffer_attr>, int)
          >('pa_stream_connect_record'),
      stream_disconnect = l.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'pa_stream_disconnect',
      ),
      stream_peek = l
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Size>),
            int Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Size>)
          >('pa_stream_peek'),
      stream_drop = l.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('pa_stream_drop');

  final Pointer<Void> Function() mainloop_new;
  final void Function(Pointer<Void>) mainloop_free;
  final Pointer<Void> Function(Pointer<Void>) mainloop_get_api;
  final int Function(Pointer<Void>, int, Pointer<Int32>) mainloop_iterate;
  final Pointer<Void> Function() proplist_new;
  final void Function(Pointer<Void>) proplist_free;
  final int Function(Pointer<Void>, PaStr, PaStr) proplist_sets;
  final PaStr Function(Pointer<Void>, PaStr) proplist_gets;
  final PaStr Function(Pointer<Void>, Pointer<Pointer<Void>>) proplist_iterate;
  final PaStr Function(int) channel_position_to_string;
  final PaStr Function(int) strerror;
  final void Function(PaOp) operation_unref;
  final PaCtx Function(Pointer<Void>, PaStr, Pointer<Void>) context_new_with_proplist;
  final void Function(PaCtx) context_unref;
  final int Function(PaCtx, PaStr, int, Pointer<Void>) context_connect;
  final void Function(PaCtx) context_disconnect;
  final int Function(PaCtx) context_get_state;
  final int Function(PaCtx) context_errno;
  final void Function(PaCtx, Pointer<NativeFunction<pa_context_notify_cb>>, PaUd) context_set_state_callback;
  final void Function(PaCtx, Pointer<NativeFunction<pa_context_subscribe_cb>>, PaUd) context_set_subscribe_callback;
  final PaOp Function(PaCtx, int, PaSuccessCb, PaUd) context_subscribe;
  final PaOp Function(PaCtx, Pointer<NativeFunction<pa_device_info_cb>>, PaUd) get_sink_info_list;
  final PaOp Function(PaCtx, Pointer<NativeFunction<pa_device_info_cb>>, PaUd) get_source_info_list;
  final PaOp Function(PaCtx, Pointer<NativeFunction<pa_sink_input_info_cb>>, PaUd) get_sink_input_info_list;
  final PaOp Function(PaCtx, Pointer<NativeFunction<pa_source_output_info_cb>>, PaUd) get_source_output_info_list;
  final PaOp Function(PaCtx, Pointer<NativeFunction<pa_card_info_cb>>, PaUd) get_card_info_list;
  final PaOp Function(PaCtx, Pointer<NativeFunction<pa_server_info_cb>>, PaUd) get_server_info;
  final PaOp Function(PaCtx, PaStr, Pointer<pa_cvolume>, PaSuccessCb, PaUd) set_sink_volume_by_name;
  final PaOp Function(PaCtx, PaStr, Pointer<pa_cvolume>, PaSuccessCb, PaUd) set_source_volume_by_name;
  final PaOp Function(PaCtx, PaStr, int, PaSuccessCb, PaUd) set_sink_mute_by_name;
  final PaOp Function(PaCtx, PaStr, int, PaSuccessCb, PaUd) set_source_mute_by_name;
  final PaOp Function(PaCtx, PaStr, PaSuccessCb, PaUd) set_default_sink;
  final PaOp Function(PaCtx, PaStr, PaSuccessCb, PaUd) set_default_source;
  final PaOp Function(PaCtx, PaStr, PaStr, PaSuccessCb, PaUd) set_sink_port_by_name;
  final PaOp Function(PaCtx, PaStr, PaStr, PaSuccessCb, PaUd) set_source_port_by_name;
  final PaOp Function(PaCtx, PaStr, PaStr, int, PaSuccessCb, PaUd) set_port_latency_offset;
  final PaOp Function(PaCtx, int, Pointer<pa_cvolume>, PaSuccessCb, PaUd) set_sink_input_volume;
  final PaOp Function(PaCtx, int, Pointer<pa_cvolume>, PaSuccessCb, PaUd) set_source_output_volume;
  final PaOp Function(PaCtx, int, int, PaSuccessCb, PaUd) set_sink_input_mute;
  final PaOp Function(PaCtx, int, int, PaSuccessCb, PaUd) set_source_output_mute;
  final PaOp Function(PaCtx, int, PaStr, PaSuccessCb, PaUd) move_sink_input_by_name;
  final PaOp Function(PaCtx, int, PaStr, PaSuccessCb, PaUd) move_source_output_by_name;
  final PaOp Function(PaCtx, int, PaSuccessCb, PaUd) kill_sink_input;
  final PaOp Function(PaCtx, int, PaSuccessCb, PaUd) kill_source_output;
  final PaOp Function(PaCtx, PaStr, PaStr, PaSuccessCb, PaUd) set_card_profile_by_name;
  final Pointer<Void> Function(PaCtx, PaStr, Pointer<pa_sample_spec>, Pointer<Void>, Pointer<Void>)
  stream_new_with_proplist;
  final void Function(Pointer<Void>) stream_unref;
  final int Function(Pointer<Void>, int) stream_set_monitor_stream;
  final void Function(Pointer<Void>, Pointer<NativeFunction<pa_stream_request_cb>>, PaUd) stream_set_read_callback;
  final int Function(Pointer<Void>, PaStr, Pointer<pa_buffer_attr>, int) stream_connect_record;
  final int Function(Pointer<Void>) stream_disconnect;
  final int Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Size>) stream_peek;
  final int Function(Pointer<Void>) stream_drop;
}
