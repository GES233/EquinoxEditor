defmodule Neume.Engine.MockPipeline.Steps.ScorePlan do
  @moduledoc false

  use Oi.Step, name: :score_plan

  alias Coconut.Score.Key
  alias Neume.Syllable

  manifest(inputs: [:notes], outputs: [plan: :any])

  routine notes, opts do
    ticks_per_frame = Keyword.fetch!(opts, :ticks_per_frame)

    case build(notes, ticks_per_frame) do
      {:ok, plan} -> ok(plan)
      {:error, _} = error -> error
    end
  end

  defp build(notes, ticks_per_frame) when is_list(notes) do
    sorted = Enum.sort_by(notes, fn {id, _note, {start_tick, _end}} -> {start_tick, id} end)
    memberships = memberships(sorted)

    Enum.reduce_while(sorted, {:ok, []}, fn
      {id, note, {start_tick, end_tick}}, {:ok, acc}
      when is_integer(start_tick) and is_integer(end_tick) and end_tick > start_tick ->
        case midi(note.key, id) do
          {:ok, midi} ->
            frame_count = div(end_tick - start_tick + ticks_per_frame - 1, ticks_per_frame)
            membership = Map.fetch!(memberships, id)

            segment = %{
              id: id,
              start_tick: start_tick,
              end_tick: end_tick,
              frame_count: frame_count,
              midi: midi,
              lyric: display_lyric(sorted, memberships, membership, note.lyric)
            }

            {:cont, {:ok, [segment | acc]}}

          {:error, _} = error ->
            {:halt, error}
        end

      malformed, _acc ->
        {:halt, {:error, {:invalid_note_view, malformed}}}
    end)
    |> case do
      {:ok, plan} -> {:ok, Enum.reverse(plan)}
      {:error, _} = error -> error
    end
  end

  # 生效续音沿用头音符的 lyric 展示（mock 没有延音记号约定）。
  defp display_lyric(_sorted, _memberships, %{continuation?: false}, lyric), do: lyric

  defp display_lyric(sorted, _memberships, %{head_id: head_id}, _lyric) do
    case Enum.find(sorted, fn {id, _note, _span} -> id == head_id end) do
      {^head_id, note, _span} -> note.lyric
      nil -> nil
    end
  end

  @doc false
  def memberships(sorted_notes) do
    sorted_notes
    |> Enum.map(fn {id, note, {start_tick, end_tick}} ->
      {id, start_tick, end_tick, Syllable.flagged?(note.metadata)}
    end)
    |> Syllable.derive_groups()
    |> Map.new(&{&1.id, &1})
  end

  defp midi(nil, id), do: {:error, {:missing_pitch, id}}

  defp midi(key, id) do
    case Coconut.Score.Key.Inner.impl_for(key) do
      nil -> {:error, {:unsupported_pitch, id}}
      _implementation -> {:ok, Key.to_midi(key)}
    end
  end
end

defmodule Neume.Engine.MockPipeline.Steps.Pitch do
  @moduledoc false

  use Oi.Step, name: :pitch

  manifest(inputs: [:plan, :pins], outputs: [f0_midi: :any])

  routine [plan, pins], _opts do
    case rasterize(plan, pins) do
      {:ok, values} -> ok(values)
      {:error, _} = error -> error
    end
  end

  defp rasterize(plan, pins) when is_list(plan) and is_map(pins) do
    known_ids = MapSet.new(plan, & &1.id)

    case Enum.find(Map.keys(pins), &(not MapSet.member?(known_ids, &1))) do
      nil -> rasterize_segments(plan, pins)
      unknown_id -> {:error, {:unknown_pitch_pin_note, unknown_id}}
    end
  end

  defp rasterize(_plan, pins), do: {:error, {:invalid_pitch_pins, pins}}

  defp rasterize_segments(plan, pins) do
    Enum.reduce_while(plan, {:ok, []}, fn segment, {:ok, acc} ->
      case rasterize_segment(segment, Map.get(pins, segment.id, [])) do
        {:ok, frames} -> {:cont, {:ok, [frames | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, segments |> Enum.reverse() |> List.flatten()}
      {:error, _} = error -> error
    end
  end

  defp rasterize_segment(segment, points) when is_list(points) do
    base = List.duplicate(segment.midi, segment.frame_count)

    Enum.reduce_while(points, {:ok, base}, fn point, {:ok, frames} ->
      with {:ok, tick, midi} <- normalize_point(point),
           :ok <- within_segment(tick, segment) do
        frame =
          div(
            (tick - segment.start_tick) * segment.frame_count,
            segment.end_tick - segment.start_tick
          )

        {:cont, {:ok, List.replace_at(frames, frame, midi * 1.0)}}
      else
        {:error, reason} ->
          {:halt, {:error, {:invalid_pitch_point, segment.id, point, reason}}}
      end
    end)
  end

  defp rasterize_segment(segment, points),
    do: {:error, {:invalid_pitch_points, segment.id, points}}

  defp normalize_point([tick, midi]) when is_integer(tick) and is_number(midi),
    do: {:ok, tick, midi}

  defp normalize_point(_point), do: {:error, :invalid_shape}

  defp within_segment(tick, %{start_tick: start_tick, end_tick: end_tick}) do
    if tick >= start_tick and tick < end_tick,
      do: :ok,
      else: {:error, :outside_note_span}
  end
end

defmodule Neume.Engine.MockPipeline.Steps.Acoustic do
  @moduledoc false

  use Oi.Step, name: :acoustic

  alias Neume.RenderArtifact

  manifest(inputs: [:plan, :f0_midi], outputs: [artifact: :any])

  routine [plan, f0_midi], _opts do
    note_ids = Enum.flat_map(plan, &List.duplicate(&1.id, &1.frame_count))
    lyrics = Enum.flat_map(plan, &List.duplicate(&1.lyric, &1.frame_count))

    %RenderArtifact{
      frame_count: length(f0_midi),
      midi: f0_midi,
      lyrics: lyrics,
      note_ids: note_ids
    }
    |> ok()
  end
end
