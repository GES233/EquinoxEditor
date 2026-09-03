defmodule Neume.Engine.DiffSingerPipeline.Steps.ScorePlan do
  @moduledoc false

  use Oi.Step, name: :score_plan

  alias Coconut.Render.Engine.Snapshot
  alias Coconut.Score.{Key, Note, TempoMap}

  @head_padding_sec 0.5

  manifest(inputs: [:snapshot, :pitch_pins, :duration_pins], outputs: [plan: :any])

  routine [snapshot, pitch_pins, duration_pins], opts do
    case build(snapshot, pitch_pins, duration_pins, Keyword.fetch!(opts, :track_id)) do
      {:ok, plan} -> ok(plan)
      {:error, _} = error -> error
    end
  end

  defp build(%Snapshot{} = snapshot, pitch_pins, duration_pins, track_id)
       when is_map(pitch_pins) and is_map(duration_pins) do
    with {:ok, view} <- Map.fetch(snapshot.tracks, track_id),
         true <- view.module == Coconut.Edit.Track.Vocal,
         {:ok, notes} <- build_notes(view.elements, snapshot),
         :ok <- validate_monophonic(notes),
         {:ok, pitch_overrides} <- build_pitch_overrides(pitch_pins, notes, snapshot),
         {:ok, duration_overrides} <-
           build_duration_overrides(duration_pins, notes, snapshot) do
      {:ok,
       %{
         notes: notes,
         duration_overrides: duration_overrides,
         pitch_overrides: pitch_overrides,
         head_padding_sec: @head_padding_sec
       }}
    else
      :error -> {:error, {:unknown_track, track_id}}
      false -> {:error, {:not_vocal_track, track_id}}
      {:error, _} = error -> error
    end
  end

  defp build(%Snapshot{} = _snapshot, pitch_pins, duration_pins, _track_id),
    do: {:error, {:invalid_pins, pitch_pins, duration_pins}}

  defp build_notes(elements, snapshot) do
    elements
    |> Enum.sort_by(fn {id, _note, {start_tick, _end_tick}} -> {start_tick, id} end)
    |> Enum.reduce_while({:ok, []}, fn
      {id, %Note{} = note, {start_tick, end_tick}}, {:ok, acc}
      when is_integer(start_tick) and is_integer(end_tick) and end_tick > start_tick ->
        with {:ok, midi} <- midi(note, id),
             {:ok, phonemes} <- phonemes(note, id) do
          entry = %{
            id: id,
            lyric: note.lyric,
            language: Map.get(note.metadata, "language", "zh"),
            phonemes: phonemes,
            midi: midi,
            start_tick: start_tick,
            end_tick: end_tick,
            start_sec: tick_to_sec(snapshot, start_tick),
            end_sec: tick_to_sec(snapshot, end_tick)
          }

          {:cont, {:ok, [entry | acc]}}
        else
          {:error, _} = error -> {:halt, error}
        end

      malformed, _acc ->
        {:halt, {:error, {:invalid_note_view, malformed}}}
    end)
    |> case do
      {:ok, notes} -> {:ok, Enum.reverse(notes)}
      {:error, _} = error -> error
    end
  end

  defp midi(%Note{key: nil}, id), do: {:error, {:missing_pitch, id}}

  defp midi(%Note{key: key}, id) do
    case Coconut.Score.Key.Inner.impl_for(key) do
      nil -> {:error, {:unsupported_pitch, id}}
      _implementation -> {:ok, Key.to_midi(key)}
    end
  end

  defp phonemes(%Note{metadata: metadata}, id) do
    case Map.get(metadata, "phonemes") do
      nil ->
        {:ok, nil}

      [_ | _] = values ->
        if Enum.all?(values, &valid_phoneme?/1),
          do: {:ok, values},
          else: {:error, {:invalid_phonemes, id}}

      other ->
        {:error, {:invalid_phonemes, id, other}}
    end
  end

  defp valid_phoneme?([language, symbol]), do: is_binary(language) and is_binary(symbol)
  defp valid_phoneme?(_other), do: false

  defp validate_monophonic(notes) do
    notes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [left, right] -> right.start_tick < left.end_tick end)
    |> case do
      nil -> :ok
      [left, right] -> {:error, {:overlapping_notes, left.id, right.id}}
    end
  end

  defp build_pitch_overrides(pins, notes, snapshot) do
    by_id = Map.new(notes, &{&1.id, &1})

    Enum.reduce_while(pins, {:ok, []}, fn {note_id, points}, {:ok, acc} ->
      with {:ok, note} <- Map.fetch(by_id, note_id),
           {:ok, converted} <- convert_points(points, note, snapshot) do
        override = %{kind: "pitch", note_id: note_id, points: converted}
        {:cont, {:ok, [override | acc]}}
      else
        :error -> {:halt, {:error, {:unknown_pitch_pin_note, note_id}}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, overrides} -> {:ok, Enum.reverse(overrides)}
      {:error, _} = error -> error
    end
  end

  defp build_duration_overrides(pins, notes, snapshot) do
    by_id = Map.new(notes, &{&1.id, &1})

    Enum.reduce_while(pins, {:ok, []}, fn {note_id, durations}, {:ok, acc} ->
      with {:ok, note} <- Map.fetch(by_id, note_id),
           {:ok, converted} <- convert_durations(durations, note, snapshot) do
        override = %{kind: "duration", note_id: note_id, durations: converted}
        {:cont, {:ok, [override | acc]}}
      else
        :error -> {:halt, {:error, {:unknown_duration_pin_note, note_id}}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, overrides} -> {:ok, Enum.reverse(overrides)}
      {:error, _} = error -> error
    end
  end

  defp convert_durations(durations, note, snapshot) when is_list(durations) do
    phoneme_count = if is_list(note.phonemes), do: length(note.phonemes), else: nil

    durations
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn
      [index, ticks], {:ok, acc, seen}
      when is_integer(index) and index >= 0 and is_integer(ticks) and ticks > 0 ->
        cond do
          is_integer(phoneme_count) and index >= phoneme_count ->
            {:halt, {:error, {:phoneme_index_out_of_range, note.id, index}}}

          MapSet.member?(seen, index) ->
            {:halt, {:error, {:duplicate_phoneme_duration, note.id, index}}}

          true ->
            seconds =
              tick_to_sec(snapshot, note.start_tick + ticks) -
                tick_to_sec(snapshot, note.start_tick)

            {:cont, {:ok, [[index, seconds] | acc], MapSet.put(seen, index)}}
        end

      point, _acc ->
        {:halt, {:error, {:invalid_phoneme_duration, note.id, point}}}
    end)
    |> case do
      {:ok, converted, _seen} -> validate_duration_budget(Enum.reverse(converted), note)
      {:error, _} = error -> error
    end
  end

  defp convert_durations(durations, note, _snapshot),
    do: {:error, {:invalid_phoneme_durations, note.id, durations}}

  defp validate_duration_budget(durations, note) do
    pinned_seconds = Enum.sum(Enum.map(durations, fn [_index, seconds] -> seconds end))
    note_seconds = note.end_sec - note.start_sec

    if pinned_seconds <= note_seconds + 1.0e-9,
      do: {:ok, durations},
      else: {:error, {:phoneme_duration_overflow, note.id}}
  end

  defp convert_points(points, note, snapshot) when is_list(points) do
    Enum.reduce_while(points, {:ok, []}, fn
      [tick, midi], {:ok, acc} when is_integer(tick) and is_number(midi) ->
        if tick >= note.start_tick and tick < note.end_tick do
          seconds = @head_padding_sec + tick_to_sec(snapshot, tick)
          {:cont, {:ok, [[seconds, midi * 1.0] | acc]}}
        else
          {:halt, {:error, {:pitch_point_outside_note, note.id, tick}}}
        end

      point, _acc ->
        {:halt, {:error, {:invalid_pitch_point, note.id, point}}}
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      {:error, _} = error -> error
    end
  end

  defp convert_points(points, note, _snapshot),
    do: {:error, {:invalid_pitch_points, note.id, points}}

  defp tick_to_sec(%Snapshot{tempo_map: nil, tpqn: tpqn}, tick), do: tick / (tpqn * 2.0)

  defp tick_to_sec(%Snapshot{tempo_map: tempo_map}, tick),
    do: TempoMap.tick_to_sec(tempo_map, tick)
end

defmodule Neume.Engine.DiffSingerPipeline.Steps.Inference do
  @moduledoc false

  use Oi.Step, name: :diffsinger

  alias Neume.RenderArtifact

  manifest(inputs: [:plan], outputs: [artifact: :any])

  routine plan, opts do
    case render(plan, opts) do
      {:ok, artifact} -> ok(artifact)
      {:error, _} = error -> error
    end
  end

  defp render(%{notes: notes} = plan, opts) when is_list(notes) and notes != [] do
    client = Keyword.fetch!(opts, :client)
    config = Keyword.fetch!(opts, :worker_config)
    globals = Keyword.fetch!(opts, :globals)

    with {:ok, phonemes} <- resolve_phonemes(notes, client, config),
         {:ok, words, word_indices} <- build_words(notes, phonemes, plan.head_padding_sec),
         overrides <-
           attach_word_indices(plan.pitch_overrides ++ plan.duration_overrides, word_indices),
         {:ok, probe} <-
           client.call(
             %{action: "check", words: words, globals: globals, overrides: overrides},
             config
           ),
         {:ok, out_path} <- output_path(Keyword.fetch!(opts, :output_dir)),
         {:ok, result} <-
           client.call(
             %{
               action: "render",
               words: words,
               globals: globals,
               overrides: overrides,
               ph_dur: Map.fetch!(probe, "ph_dur"),
               pitch_pred_midi: Map.fetch!(probe, "pitch_pred_midi"),
               out_path: out_path
             },
             config
           ),
         {:ok, boundaries} <- attach_note_ids(Map.get(probe, "phonemes"), notes) do
      {:ok,
       %RenderArtifact{
         format: :wav,
         frame_count: Map.fetch!(result, "frames"),
         path: Map.fetch!(result, "path"),
         sample_rate: Map.fetch!(result, "sample_rate"),
         sample_count: Map.get(result, "samples"),
         duration_sec: Map.get(result, "duration_sec"),
         lead_in_sec: Map.get(probe, "lead_in_sec", plan.head_padding_sec),
         phonemes: boundaries,
         phoneme_durations: Map.fetch!(probe, "ph_dur")
       }}
    end
  end

  defp render(%{notes: []}, _opts), do: {:error, :empty_score}
  defp render(plan, _opts), do: {:error, {:invalid_score_plan, plan}}

  defp resolve_phonemes(notes, client, config) do
    missing = Enum.filter(notes, &is_nil(&1.phonemes))

    if missing == [] do
      {:ok, %{}}
    else
      request_notes =
        Enum.map(missing, fn note ->
          %{id: note.id, lyric: note.lyric, language: note.language}
        end)

      with {:ok, %{"tokens" => tokens}} <-
             client.call(%{action: "encode", notes: request_notes}, config),
           [] <- Enum.reject(missing, &Map.has_key?(tokens, to_string(&1.id))) do
        {:ok, tokens}
      else
        [_ | _] = unresolved -> {:error, {:encoder_incomplete, Enum.map(unresolved, & &1.id)}}
        {:error, reason} -> {:error, {:encoder_failed, reason}}
        other -> {:error, {:invalid_encoder_result, other}}
      end
    end
  end

  defp build_words(notes, resolved, head_padding_sec) do
    first_language = notes |> hd() |> language_for()
    head = [[[[first_language, "SP"]], head_padding_sec, 0.0]]

    {words, indices, _previous} =
      Enum.reduce(notes, {head, %{}, nil}, fn note, {words, indices, previous} ->
        rest = gap_word(previous, note)
        word_index = length(words) + length(rest)
        phonemes = note.phonemes || Map.fetch!(resolved, to_string(note.id))
        word = [phonemes, note.end_sec - note.start_sec, note.midi * 1.0]

        {words ++ rest ++ [word], Map.put(indices, note.id, word_index), note}
      end)

    {:ok, words, indices}
  end

  defp gap_word(nil, note) do
    if note.start_sec > 1.0e-9,
      do: [[[[language_for(note), "SP"]], note.start_sec, 0.0]],
      else: []
  end

  defp gap_word(previous, note) do
    gap = note.start_sec - previous.end_sec

    if gap > 1.0e-9,
      do: [[[[language_for(previous), "SP"]], gap, 0.0]],
      else: []
  end

  defp language_for(%{phonemes: [[language, _symbol] | _]}), do: language
  defp language_for(note), do: note.language

  defp attach_word_indices(overrides, word_indices) do
    Enum.map(overrides, fn override ->
      override
      |> Map.put(:note_index, Map.fetch!(word_indices, override.note_id))
      |> Map.delete(:note_id)
    end)
  end

  defp attach_note_ids(boundaries, notes) when is_list(boundaries) do
    Enum.reduce_while(boundaries, {:ok, []}, fn boundary, {:ok, acc} ->
      with %{} <- boundary,
           {:ok, note_id} <- boundary_note_id(boundary["note_index"], notes),
           {:ok, normalized} <- normalize_boundary(boundary, note_id) do
        {:cont, {:ok, [normalized | acc]}}
      else
        _other -> {:halt, {:error, {:invalid_phoneme_boundary, boundary}}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _} = error -> error
    end
  end

  defp attach_note_ids(nil, _notes), do: {:ok, []}
  defp attach_note_ids(other, _notes), do: {:error, {:invalid_phoneme_boundaries, other}}

  defp boundary_note_id(nil, _notes), do: {:ok, nil}

  defp boundary_note_id(index, notes)
       when is_integer(index) and index >= 0 and index < length(notes),
       do: {:ok, Enum.at(notes, index).id}

  defp boundary_note_id(_index, _notes), do: :error

  defp normalize_boundary(boundary, note_id) do
    with language when is_binary(language) <- boundary["language"],
         symbol when is_binary(symbol) <- boundary["symbol"],
         type when is_binary(type) or is_nil(type) <- boundary["type"],
         start_frame when is_integer(start_frame) and start_frame >= 0 <-
           boundary["start_frame"],
         end_frame when is_integer(end_frame) and end_frame >= start_frame <-
           boundary["end_frame"],
         phoneme_index when is_integer(phoneme_index) and phoneme_index >= 0 <-
           boundary["phoneme_index"] do
      {:ok,
       %{
         language: language,
         symbol: symbol,
         type: type,
         start_frame: start_frame,
         end_frame: end_frame,
         note_id: note_id,
         phoneme_index: phoneme_index
       }}
    else
      _other -> :error
    end
  end

  defp output_path(directory) do
    with :ok <- File.mkdir_p(directory) do
      filename = "render_#{System.unique_integer([:positive, :monotonic])}.wav"
      {:ok, directory |> Path.join(filename) |> Path.expand()}
    end
  end
end
