defmodule Neume.Output do
  @moduledoc "模型输出干预：局部底料投影、精确签名与 Orchid 输出合并。"
  @behaviour OrchidIntervention.Operate

  @schema "model_output_v1"
  def schema, do: @schema
  def payload?(%{schema: @schema}), do: true
  def payload?(_), do: false

  # 必须运行 producer；不能用 override 短路掉待裁决的底料。
  @impl true
  def data_enable, do: {true, true}

  @doc "按音符实际音素边界投影；时轴与音素对应关系也是底料。"
  def project(packet, note_id) do
    segments = Enum.filter(packet.segments, &(&1.note_id == note_id))

    case segments do
      [] ->
        {:error, {:output_region_unavailable, note_id}}

      _ ->
        first = Enum.min_by(segments, & &1.start_frame).start_frame
        last = Enum.max_by(segments, & &1.end_frame).end_frame

        indices =
          for {segment, index} <- Enum.with_index(packet.segments),
              segment.note_id == note_id,
              do: index

        values =
          if packet.channel == :pitch,
            do: Enum.slice(packet.values, first, last - first),
            else: Enum.map(indices, &Enum.at(packet.values, &1))

        offset = round((packet.origin_sec - packet.lead_in_sec) * packet.frame_rate)

        shape =
          Enum.map(
            segments,
            &%{
              language: &1.language,
              phoneme: &1.symbol,
              start: &1.start_frame - first,
              end: &1.end_frame - first
            }
          )

        base = %{
          schema: "model_output_base_v1",
          channel: Atom.to_string(packet.channel),
          start_frame: first + offset,
          end_frame: last + offset,
          frame_rate: exact(packet.frame_rate),
          segments: shape,
          values: Enum.map(values, &exact/1)
        }

        with {:ok, digest} <- Tamale.Digest.digest(base) do
          {:ok,
           %{
             base: base,
             digest: digest,
             values: values,
             segments: shape,
             start_frame: first,
             end_frame: last,
             indices: indices,
             start_sec: (first + offset) / packet.frame_rate,
             frame_rate: packet.frame_rate
           }}
        end
    end
  end

  # IEEE 字节是精确、可持久化的 canonical 字符串，不设模糊相等容差。
  defp exact(value) when is_integer(value), do: value
  defp exact(value) when is_float(value), do: Base.encode16(<<value::float-64>>, case: :lower)

  @doc "duration 改音素帧长，保持所选区域预算；pitch 点的横轴为区域内帧偏移。"
  def validate(:duration, values, projection) when is_list(values) do
    if length(values) == length(projection.values) and
         Enum.all?(values, &(is_integer(&1) and &1 >= 0)) and
         Enum.sum(values) > 0 and
         Enum.sum(values) == Enum.sum(projection.values),
       do: :ok,
       else: {:error, :invalid_duration_budget}
  end

  def validate(:pitch, points, projection) when is_list(points) and length(points) in 1..256 do
    frames = projection.end_frame - projection.start_frame

    valid =
      Enum.all?(points, fn
        [frame, midi] when is_integer(frame) and is_number(midi) ->
          frame >= 0 and frame < frames and midi >= 0 and midi <= 127

        _ ->
          false
      end)

    ordered =
      Enum.all?(Enum.chunk_every(points, 2, 1, :discard), fn
        [[a, _], [b, _]] -> a < b
        _ -> false
      end)

    if valid and ordered, do: :ok, else: {:error, :invalid_output_pitch_points}
  end

  def validate(_, _, _), do: {:error, :invalid_output_values}

  @impl true
  def merge(packet, pins) do
    # 同一阶段每份底料都取 producer 输出，不把旁边刚应用的修改当作旧底料。
    projections = if Map.get(packet, :available, true), do: projections(packet), else: %{}

    merge_projections(packet, pins, projections)
  end

  defp projections(packet) do
    Map.new(Enum.reject(Enum.uniq(Enum.map(packet.segments, & &1.note_id)), &is_nil/1), fn id ->
      {id, project(packet, id)}
    end)
  end

  defp merge_projections(packet, pins, projections) do
    packet =
      Map.put(
        packet,
        :projections,
        Map.put(Map.get(packet, :projections, %{}), packet.channel, projections)
      )

    Enum.reduce(pins, {:ok, packet}, fn {note_id, pin}, {:ok, acc} ->
      result =
        with true <- packet.entries == [],
             {:ok, projection} <-
               Map.get(projections, note_id, {:error, :output_region_unavailable}),
             {:ok, values} <-
               Tamale.Patch.resolve(
                 %Tamale.Patch{base_digest: pin.base_digest, payload: pin.values},
                 projection.base
               ),
             :ok <- validate(packet.channel, values, projection) do
          {:ok, apply_values(acc, projection, values)}
        else
          false -> {:error, :upstream_output_conflict}
          {:conflict, reason} -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end

      case result do
        {:ok, next} ->
          {:ok, next}

        {:error, reason} ->
          entry = %{
            kind: :conflict,
            stage: :output,
            channel: packet.channel,
            patch_id: pin.patch_id,
            note_id: note_id,
            reason: reason
          }

          {:ok, %{acc | entries: acc.entries ++ [entry]}}
      end
    end)
  end

  defp apply_values(%{channel: :duration} = packet, projection, values) do
    replacements = Map.new(Enum.zip(projection.indices, values))

    durations =
      packet.values
      |> Enum.with_index()
      |> Enum.map(fn {value, i} -> Map.get(replacements, i, value) end)

    {segments, _} =
      Enum.map_reduce(Enum.zip(packet.segments, durations), 0, fn {segment, frames}, start ->
        {%{segment | start_frame: start, end_frame: start + frames}, start + frames}
      end)

    %{packet | values: durations, segments: segments}
  end

  defp apply_values(%{channel: :pitch} = packet, projection, points) do
    [[first, _] | _] = points
    [last, _] = List.last(points)

    replacements =
      Map.new(first..last, fn frame ->
        {projection.start_frame + frame, interpolate(points, frame)}
      end)

    values =
      packet.values
      |> Enum.with_index()
      |> Enum.map(fn {value, i} -> Map.get(replacements, i, value) end)

    %{packet | values: values}
  end

  defp interpolate([[_, midi]], _frame), do: midi * 1.0

  defp interpolate([[a, x], [b, y] | tail], frame) do
    if frame <= b,
      do: x + (y - x) * (frame - a) / (b - a),
      else: interpolate([[b, y] | tail], frame)
  end

  def pins?(pins),
    do: Enum.any?(pins, fn {_, notes} -> Enum.any?(notes, fn {_, p} -> payload?(p) end) end)

  def split(pins) do
    Map.new([:duration, :pitch], fn channel ->
      {output, legacy} =
        Enum.split_with(Map.get(pins, channel, %{}), fn {_, value} -> payload?(value) end)

      {channel, %{output: Map.new(output), legacy: Map.new(legacy)}}
    end)
  end
end
