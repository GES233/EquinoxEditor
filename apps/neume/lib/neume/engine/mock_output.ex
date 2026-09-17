defmodule Neume.Engine.MockOutput do
  @moduledoc "确定性的演示输出 producer；与真引擎共用 OutputPipeline 和干预裁决。"
  alias Neume.Engine.MockPipeline

  def packets(state, snapshot, pins, globals, track_id) do
    with {:ok, phrases} <- Neume.Phrase.split(snapshot, track_id, pins) do
      Enum.reduce_while(phrases, {:ok, []}, fn phrase, {:ok, acc} ->
        case Neume.OutputPipeline.run(
               __MODULE__,
               state,
               phrase.snapshot,
               phrase.pins,
               globals,
               track_id
             ) do
          {:ok, packet} -> {:cont, {:ok, acc ++ [packet]}}
          error -> {:halt, error}
        end
      end)
    end
  end

  def output_duration(state, input) do
    # 演示暂不混合旧输入约束与新输出修改，避免假装模拟了 DiffSinger retake。
    if Enum.any?(input.pins, fn {_, notes} -> map_size(notes) > 0 end) do
      {:error, :mock_legacy_output_mix_unsupported}
    else
      with {:ok, analysis} <-
             MockPipeline.analyze(
               state,
               input.snapshot,
               input.pins,
               input.globals,
               input.track_id
             ) do
        notes = input.snapshot.tracks[input.track_id].elements

        pitches =
          Map.new(notes, fn {id, note, _} -> {id, Coconut.Score.Key.to_midi(note.key)} end)

        analysis = align(analysis, notes, input.snapshot, state.ticks_per_frame)

        {:ok,
         %{
           channel: :duration,
           values: analysis.phoneme_durations,
           segments: analysis.phonemes,
           frame_rate: analysis.frame_rate,
           origin_sec: analysis.origin_sec,
           lead_in_sec: analysis.lead_in_sec,
           entries: [],
           projections: %{},
           context: %{analysis: analysis, pitches: pitches}
         }}
      end
    end
  end

  def output_pitch(_state, duration) do
    values =
      Enum.flat_map(duration.segments, fn segment ->
        count = segment.end_frame - segment.start_frame
        midi = Map.get(duration.context.pitches, segment.note_id, 0)

        if count == 0,
          do: [],
          else:
            for(
              i <- 0..(count - 1),
              do:
                if(is_nil(segment.note_id),
                  do: 0.0,
                  else: midi + 0.2 * :math.sin(i / max(count - 1, 1) * :math.pi())
                )
            )
      end)

    context = Map.put(duration.context, :durations, duration.values)
    {:ok, %{duration | channel: :pitch, values: values, context: context}}
  end

  def analysis(packet) do
    %{
      packet.context.analysis
      | pitch_pred_midi: packet.values,
        phonemes: packet.segments,
        phoneme_durations: packet.context.durations
    }
  end

  # 演示输出使用固定帧率与歌曲时间轴，休止也占帧，移动邻居不会压缩所选区域。
  defp align(analysis, notes, snapshot, ticks_per_frame) do
    rate = 960.0 / ticks_per_frame
    sorted = Enum.sort_by(notes, fn {id, _, {start, _}} -> {start, id} end)
    {_, _, {start_tick, _}} = hd(sorted)
    origin = sec(snapshot, start_tick)
    origin_frame = round(origin * rate)

    {segments, total} =
      Enum.reduce(sorted, {[], 0}, fn {id, _, {a, b}}, {acc, cursor} ->
        first = round(sec(snapshot, a) * rate) - origin_frame
        last = round(sec(snapshot, b) * rate) - origin_frame
        owned = Enum.filter(analysis.phonemes, &(&1.note_id == id))
        count = length(owned)

        acc =
          if first > cursor,
            do:
              acc ++
                [
                  %{
                    language: "",
                    symbol: "SP",
                    type: nil,
                    note_id: nil,
                    phoneme_index: 0,
                    start_frame: cursor,
                    end_frame: first
                  }
                ],
            else: acc

        {owned, finish} =
          Enum.map_reduce(Enum.with_index(owned), first, fn {segment, i}, at ->
            frames = div(last - first, count) + if(i < rem(last - first, count), do: 1, else: 0)
            {%{segment | start_frame: at, end_frame: at + frames}, at + frames}
          end)

        {acc ++ owned, finish}
      end)

    %{
      analysis
      | phonemes: segments,
        phoneme_durations: Enum.map(segments, &(&1.end_frame - &1.start_frame)),
        frame_rate: rate,
        origin_sec: origin_frame / rate,
        total_frames: total
    }
  end

  defp sec(%{tempo_map: nil, tpqn: tpqn}, tick), do: tick / (tpqn * 2.0)
  defp sec(snapshot, tick), do: Coconut.Score.TempoMap.tick_to_sec(snapshot.tempo_map, tick)
end
