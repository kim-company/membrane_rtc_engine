if Enum.all?(
     [
       Membrane.H264.FFmpeg.Parser,
       Membrane.H264.Parser,
       Membrane.HTTPAdaptiveStream.SinkBin,
       Membrane.Opus.Decoder,
       Membrane.AAC.Parser,
       Membrane.AAC.FDK.Encoder
     ],
     &Code.ensure_loaded?/1
   ) do
  defmodule Membrane.RTC.Engine.Endpoint.HLS do
    @moduledoc """
    An Endpoint responsible for converting incoming tracks to HLS playlist.
    This module requires the following plugins to be present in your `mix.exs` for H264 & OPUS input:
    ```
    [
      :membrane_h264_ffmpeg_plugin,
      :membrane_h264_plugin,
      :membrane_http_adaptive_stream_plugin,
      :membrane_opus_plugin,
      :membrane_aac_plugin,
      :membrane_aac_fdk_plugin
    ]
    ```
    It can perform mixing audio and composing video (see `Membrane.RTC.Engine.Endpoint.HLS.MixerConfig`),
    in such case these plugins are also needed:
    ```
    [
      :membrane_video_compositor_plugin,
      :membrane_audio_mix_plugin
    ]
    ```
    """
    use Membrane.Bin

    require Membrane.Logger

    alias Membrane.RTC.Engine
    alias Membrane.RTC.Engine.Endpoint.HLS.{HLSConfig, MixerConfig}
    alias Membrane.RTC.Engine.Endpoint.WebRTC.TrackReceiver
    alias Membrane.RTC.Engine.Track

    @compositor_deps [
      Membrane.H264.FFmpeg.Decoder,
      Membrane.H264.FFmpeg.Encoder
    ]
    @audio_mixer_deps [
      Membrane.AudioMixer,
      Membrane.AAC.Parser,
      Membrane.AAC.FDK.Encoder
    ]

    @track_children [
      :opus_decoder,
      :aac_encoder,
      :aac_parser,
      :video_parser,
      :decoder,
      :track_receiver,
      :depayloader
    ]

    @toilet_capacity 500
    @terminate_timeout 5000

    def_input_pad :input,
      demand_unit: :buffers,
      accepted_format: _any,
      availability: :on_request

    def_options rtc_engine: [
                  spec: pid(),
                  description: "Pid of parent Engine"
                ],
                owner: [
                  spec: pid(),
                  description: """
                  Pid of parent all notifications will be send to.
                  These notifications are:
                  * `{:playlist_playable, content_type}`
                  * `{:cleanup, clean_function}`
                  """
                ],
                output_directory: [
                  spec: Path.t(),
                  description: "Path to directory under which HLS output will be saved",
                  default: "hls_output"
                ],
                synchronize_tracks?: [
                  spec: boolean(),
                  default: true,
                  description: """
                  Set to false if source is different than webrtc.
                  If set to true HLS Endpoint will calculate track offset based on `handle_pad_added` call.
                  """
                ],
                mixer_config: [
                  spec: MixerConfig.t() | nil,
                  default: nil,
                  description: """
                  Audio and video mixer configuration. If you don't want to use compositor pass nil.
                  """
                ],
                hls_config: [
                  spec: HLSConfig.t(),
                  default: %HLSConfig{},
                  description: """
                  HLS stream and playlist configuration.
                  """
                ]

    @impl true
    def handle_init(_context, options) do
      state =
        options
        |> Map.from_struct()
        |> Map.merge(%{
          tracks: %{},
          stream_beginning: nil,
          terminating?: false,
          start_mixing_sent?: false
        })

      {[notify_parent: :ready], state}
    end

    @impl true
    def handle_playing(_context, %{mixer_config: nil} = state), do: {[], state}

    @impl true
    def handle_playing(context, state) do
      spec =
        generate_audio_mixer(state, context) ++
          generate_compositor(state, context) ++
          get_hls_sink_spec(state)

      {[spec: spec], state}
    end

    @impl true
    def handle_pad_removed(Pad.ref(:input, track_id), ctx, state) do
      track_children =
        @track_children
        |> Enum.map(&{&1, track_id})
        |> Enum.filter(&Map.has_key?(ctx.children, &1))

      {removed_track, tracks} = Map.pop!(state.tracks, track_id)
      state = %{state | tracks: tracks}

      sink_bin_used? =
        Enum.any?(tracks, fn {_id, track} ->
          track.stream_id == removed_track.stream_id
        end)

      children_to_remove =
        if is_nil(state.mixer_config) and not sink_bin_used? do
          [{:hls_sink_bin, removed_track.stream_id}]
        else
          []
        end

      children_to_remove = track_children ++ children_to_remove

      {[remove_child: children_to_remove], state}
    end

    @impl true
    def handle_pad_added(Pad.ref(:input, _track_id), _ctx, %{terminating?: true}) do
      raise "Cannot add new input pad when hls enpoint is terminating"
    end

    @impl true
    def handle_pad_added(
          Pad.ref(:input, track_id) = pad,
          ctx,
          state
        ) do
      {offset, state} = get_track_offset(state)

      track = Map.get(state.tracks, track_id)
      track_spec = get_track_spec(offset, bin_input(pad), track, state)

      {spec, state} =
        if hls_sink_bin_exists?(track, ctx, state) do
          {track_spec, state}
        else
          hls_sink_spec = get_hls_sink_spec(state, track.stream_id)
          {track_spec ++ hls_sink_spec, state}
        end

      {notify_children, state} = maybe_start_mixing(state)
      actions = [spec: spec] ++ notify_children

      {actions, state}
    end

    defp maybe_start_mixing(%{mixer_config: nil} = state) do
      {[], state}
    end

    defp maybe_start_mixing(%{start_mixing_sent?: false} = state) do
      notify_children = [
        notify_child: {:audio_mixer, {:start_mixing, Membrane.Time.milliseconds(200)}},
        notify_child: {:compositor, {:start_composing, Membrane.Time.milliseconds(200)}}
      ]

      {notify_children, %{state | start_mixing_sent?: true}}
    end

    defp maybe_start_mixing(state) do
      {[], state}
    end

    @impl true
    def handle_child_notification(
          :end_of_stream,
          {:hls_sink_bin, stream},
          _ctx,
          state
        ) do
      actions = [notify_parent: {:forward_to_parent, {:end_of_stream, stream}}]
      terminate_action = if state.terminating?, do: [terminate: :normal], else: []

      {actions ++ terminate_action, state}
    end

    def handle_child_notification(
          {:track_playable, data},
          {:hls_sink_bin, stream_id},
          _ctx,
          state
        ) do
      content_type =
        case data do
          {content_type, _track_id} -> content_type
          content_type -> content_type
        end

      output_dir = get_hls_stream_directory(state, stream_id)
      send(state.owner, {:playlist_playable, content_type, output_dir})
      {[], state}
    end

    @impl true
    def handle_child_notification(notification, _element, _context, state) do
      Membrane.Logger.warn("Unexpected notification: #{inspect(notification)}. Ignoring.")
      {[], state}
    end

    @impl true
    def handle_parent_notification({:new_tracks, tracks}, ctx, state) do
      {:endpoint, endpoint_id} = ctx.name

      state =
        Enum.reduce(tracks, state, fn track, state ->
          case Engine.subscribe(state.rtc_engine, endpoint_id, track.id) do
            :ok ->
              put_in(state, [:tracks, track.id], track)

            {:error, :invalid_track_id} ->
              Membrane.Logger.debug("""
              Couldn't subscribe to the track: #{inspect(track.id)}. No such track.
              It had to be removed just after publishing it. Ignoring.
              """)

              state

            {:error, reason} ->
              raise "Couldn't subscribe to the track: #{inspect(track.id)}. Reason: #{inspect(reason)}"
          end
        end)

      {[], state}
    end

    @impl true
    def handle_parent_notification(msg, _ctx, state) do
      Membrane.Logger.warn("Unexpected message: #{inspect(msg)}. Ignoring.")
      {[], state}
    end

    @impl true
    def handle_terminate_request(_ctx, %{mixer_config: nil} = state),
      do: {[terminate: :normal], state}

    @impl true
    def handle_terminate_request(ctx, state) do
      Process.send_after(self(), :terminate, @terminate_timeout)

      actions =
        if Map.has_key?(ctx.children, :audio_mixer) do
          [
            notify_child: {:audio_mixer, :schedule_eos},
            notify_child: {:compositor, :schedule_eos}
          ]
        else
          []
        end

      children_to_remove =
        state.tracks
        |> Enum.flat_map(fn {id, _track} -> Enum.map(@track_children, &{&1, id}) end)
        |> Enum.filter(&Map.has_key?(ctx.children, &1))

      actions = actions ++ [remove_child: children_to_remove]
      {actions, %{state | terminating?: true}}
    end

    @impl true
    def handle_info(:terminate, _ctx, %{terminating?: true} = state),
      do: {[terminate: :normal], state}

    @impl true
    def handle_info(_msg, _ctx, state), do: {[], state}

    defp get_hls_sink_spec(state, stream_id \\ nil) do
      directory = get_hls_stream_directory(state, stream_id)

      File.rm_rf(directory)
      File.mkdir_p!(directory)

      config =
        state.hls_config
        |> Map.update!(:storage, fn storage -> storage.(directory) end)
        |> Map.put(:mp4_parameters_in_band?, is_nil(state.mixer_config))

      hls_sink = struct(Membrane.HTTPAdaptiveStream.SinkBin, Map.from_struct(config))

      child_name =
        if is_nil(state.mixer_config),
          do: {:hls_sink_bin, stream_id},
          else: {:hls_sink_bin, :muxed}

      [child(child_name, hls_sink)]
    end

    defp get_track_spec(
           offset,
           link_builder,
           track,
           state
         ) do
      get_depayloading_track_spec(link_builder, track) ++
        attach_track_spec(offset, track, state)
    end

    defp get_depayloading_track_spec(link_builder, track),
      do: [
        link_builder
        |> child({:track_receiver, track.id}, %TrackReceiver{
          track: track,
          initial_target_variant: :high
        })
        |> child({:depayloader, track.id}, get_depayloader(track))
      ]

    defp attach_track_spec(offset, %{type: :audio} = track, state),
      do: attach_audio_track_spec(offset, track, state)

    defp attach_track_spec(offset, %{type: :video} = track, state),
      do: attach_video_track_spec(offset, track, state)

    defp attach_audio_track_spec(_offset, track, %{mixer_config: nil} = state),
      do: [
        get_child({:depayloader, track.id})
        |> child({:opus_decoder, track.id}, Membrane.Opus.Decoder)
        |> child({:aac_encoder, track.id}, Membrane.AAC.FDK.Encoder)
        |> child({:aac_parser, track.id}, %Membrane.AAC.Parser{out_encapsulation: :none})
        |> via_in(Pad.ref(:input, {:audio, track.id}),
          options: [
            encoding: :AAC,
            segment_duration: state.hls_config.segment_duration,
            partial_segment_duration: state.hls_config.partial_segment_duration
          ]
        )
        |> get_child({:hls_sink_bin, track.stream_id})
      ]

    if Enum.all?(@audio_mixer_deps, &Code.ensure_loaded?/1) do
      defp attach_audio_track_spec(offset, track, _state),
        do: [
          get_child({:depayloader, track.id})
          |> child({:opus_decoder, track.id}, Membrane.Opus.Decoder)
          |> via_in(Pad.ref(:input, {:extra, track.id}), options: [offset: offset])
          |> get_child(:audio_mixer)
        ]
    else
      defp attach_audio_track_spec(_offset, _track, _state),
        do: raise_missing_deps(:audio, @audio_mixer_deps)
    end

    defp attach_video_track_spec(_offset, track, %{mixer_config: nil} = state),
      do: [
        get_child({:depayloader, track.id})
        |> child({:video_parser, track.id}, h264_parser_spec(track))
        |> via_in(Pad.ref(:input, {:video, track.id}),
          options: [
            encoding: :H264,
            segment_duration: state.hls_config.segment_duration,
            partial_segment_duration: state.hls_config.partial_segment_duration
          ]
        )
        |> get_child({:hls_sink_bin, track.stream_id})
      ]

    if Enum.all?(@compositor_deps, &Code.ensure_loaded?/1) do
      defp attach_video_track_spec(offset, track, _state),
        do: [
          get_child({:depayloader, track.id})
          # TODO change to new parser once it supports Membrane.H264 stream format on input pad
          |> child({:video_parser, track.id}, %Membrane.H264.FFmpeg.Parser{
            attach_nalus?: true,
            alignment: :au
          })
          |> child({:decoder, track.id}, Membrane.H264.FFmpeg.Decoder)
          |> via_in(Pad.ref(:input, track.id),
            options: [timestamp_offset: offset]
          )
          |> get_child(:compositor)
        ]
    else
      defp attach_video_track_spec(_offset, track, _state),
        do: raise_missing_deps(:video, @compositor_deps)
    end

    defp generate_compositor(%{mixer_config: nil}, _ctx), do: []

    if Enum.all?(@compositor_deps, &Code.ensure_loaded?/1) do
      defp generate_compositor(_state, ctx) when is_map_key(ctx.children, :compositor), do: []

      defp generate_compositor(state, _ctx) do
        compositor = %Membrane.VideoCompositor{
          output_stream_format: state.mixer_config.video.stream_format,
          handler: Membrane.RTC.Engine.Endpoint.HLS.CompositorHandler,
          queuing_strategy: %Membrane.VideoCompositor.QueueingStrategy.Live{
            latency: :wait_for_start_event,
            eos_strategy: :schedule_eos
          }
        }

        # TODO change to new parser once it supports Membrane.H264 stream format on input pad
        video_parser_out = %Membrane.H264.FFmpeg.Parser{
          alignment: :au,
          attach_nalus?: true
        }

        {frames_per_second, 1} = state.mixer_config.video.stream_format.framerate
        seconds_number = Membrane.Time.as_seconds(state.hls_config.segment_duration)

        [
          child(:compositor, compositor)
          |> child(:encoder, %Membrane.H264.FFmpeg.Encoder{
            profile: :baseline,
            tune: :zerolatency,
            gop_size: frames_per_second * seconds_number
          })
          |> child(:video_parser_out, video_parser_out)
          |> via_in(Pad.ref(:input, :video),
            toilet_capacity: @toilet_capacity,
            options: [
              encoding: :H264,
              segment_duration: state.hls_config.segment_duration,
              partial_segment_duration: state.hls_config.partial_segment_duration
            ]
          )
          |> get_child({:hls_sink_bin, :muxed})
        ]
      end
    else
      defp generate_compositor(_state, _ctx), do: raise_missing_deps(:video, @compositor_deps)
    end

    defp generate_audio_mixer(%{mixer_config: nil}, _ctx), do: []

    if Enum.all?(@audio_mixer_deps, &Code.ensure_loaded?/1) do
      defp generate_audio_mixer(_state, ctx) when is_map_key(ctx.children, :audio_mixer), do: []

      defp generate_audio_mixer(state, _ctx) do
        [
          child(:audio_mixer, %Membrane.LiveAudioMixer{
            latency: nil,
            stream_format: %Membrane.RawAudio{
              channels: 1,
              sample_rate: 48_000,
              sample_format: :s16le
            }
          })
          |> child(:aac_encoder, Membrane.AAC.FDK.Encoder)
          |> via_in(:input, toilet_capacity: @toilet_capacity)
          |> child(:aac_parser, %Membrane.AAC.Parser{out_encapsulation: :none})
          |> via_in(Pad.ref(:input, :audio),
            options: [
              encoding: :AAC,
              segment_duration: state.hls_config.segment_duration,
              partial_segment_duration: state.hls_config.partial_segment_duration
            ]
          )
          |> get_child({:hls_sink_bin, :muxed})
        ]
      end
    else
      defp generate_audio_mixer(_state, _ctx), do: raise_missing_deps(:audio, @audio_mixer_deps)
    end

    defp get_track_offset(%{synchronize_tracks?: false} = state), do: {0, state}

    defp get_track_offset(%{stream_beginning: nil} = state),
      do: {0, %{state | stream_beginning: System.monotonic_time()}}

    defp get_track_offset(state), do: {System.monotonic_time() - state.stream_beginning, state}

    defp hls_sink_bin_exists?(track, ctx, %{mixer_config: nil}),
      do: Map.has_key?(ctx.children, {:hls_sink_bin, track.stream_id})

    defp hls_sink_bin_exists?(_track, ctx, _state),
      do: Map.has_key?(ctx.children, {:hls_sink_bin, :muxed})

    defp get_depayloader(track) do
      track
      |> Track.get_depayloader()
      |> tap(&unless &1, do: raise("Couldn't find depayloader for track #{inspect(track)}"))
    end

    defp get_hls_stream_directory(%{mixer_config: nil} = state, stream_id),
      do: Path.join(state.output_directory, stream_id)

    defp get_hls_stream_directory(state, _stream_id), do: state.output_directory

    defp h264_parser_spec(track) do
      {sps, pps} =
        case Map.get(track.fmtp, :sprop_parameter_sets) do
          nil -> {<<>>, <<>>}
          %{sps: sps, pps: pps} -> {<<0, 0, 0, 1>> <> sps, <<0, 0, 0, 1>> <> pps}
        end

      %Membrane.H264.Parser{
        # FIXME: surely there must be a better way to do this
        framerate: {0, 1},
        sps: sps,
        pps: pps
      }
    end

    unless Enum.all?(@compositor_deps ++ @audio_mixer_deps, &Code.ensure_loaded?/1) do
      defp merge_strings(strings), do: Enum.join(strings, ", ")

      defp raise_missing_deps(type, deps) do
        raise """
        Cannot find some of the modules required to use the #{type} mixer.
        Ensure that the following dependencies are added to the deps.
        #{merge_strings(deps)}
        """
      end
    end
  end
end
