defmodule Neume.Engine.DiffSingerPipeline.Steps.ScorePlan do
  @moduledoc false

  use Oi.Step, name: :score_plan

  alias Coconut.Render.Engine.Snapshot
  alias Coconut.Score.{Key, Note, TempoMap}
  alias Neume.{PitchCurve, Syllable}

  @head_padding_sec 0.5

  manifest(inputs: [:snapshot, :pitch_pins, :duration_pins, :globals], outputs: [plan: :any])

  routine [snapshot, pitch_pins, duration_pins, globals], opts do
    case build(
           snapshot,
           pitch_pins,
           duration_pins,
           globals,
           Keyword.fetch!(opts, :track_id),
           opts
         ) do
      {:ok, plan} -> ok(plan)
      {:error, _} = error -> error
    end
  end

  # 公开给挂载 probe（`DiffSingerPipeline.phonemes/3`）：pins 传 %{} 时
  # 只产出 score 装配（notes/groups/时基），不带任何 override。
  @doc false
  @spec build(Snapshot.t(), map(), map(), term()) :: {:ok, map()} | {:error, term()}
  def build(%Snapshot{} = snapshot, pitch_pins, duration_pins, track_id),
    do: build(snapshot, pitch_pins, duration_pins, %{}, track_id, [])

  # globals：data 里的会话旋钮覆盖编译期默认（`opts[:globals]`），随 plan
  # 流向 Analysis/Synthesis——旋钮直接进 render，不是 patch 干预。
  def build(%Snapshot{} = snapshot, pitch_pins, duration_pins, globals, track_id, opts)
      when is_map(pitch_pins) and is_map(duration_pins) and is_map(globals) do
    with {:ok, view} <- Map.fetch(snapshot.tracks, track_id),
         true <- view.module == Coconut.Edit.Track.Vocal,
         {:ok, notes} <- build_notes(view.elements, snapshot),
         notes = attach_groups(notes),
         :ok <- validate_monophonic(notes),
         {:ok, origin_sec} <- build_origin(notes),
         {:ok, pitch_overrides} <-
           build_pitch_overrides(
             pitch_pins,
             notes,
             snapshot,
             origin_sec,
             Keyword.get(opts, :frame_rate)
           ),
         {:ok, duration_overrides} <-
           build_duration_overrides(duration_pins, notes, snapshot) do
      {:ok,
       %{
         notes: rebase_notes(notes, origin_sec),
         origin_sec: origin_sec,
         duration_overrides: duration_overrides,
         pitch_overrides: pitch_overrides,
         head_padding_sec: @head_padding_sec,
         globals: Map.merge(Keyword.get(opts, :globals, %{}), globals)
       }}
    else
      :error -> {:error, {:unknown_track, track_id}}
      false -> {:error, {:not_vocal_track, track_id}}
      {:error, _} = error -> error
    end
  end

  def build(%Snapshot{} = _snapshot, pitch_pins, duration_pins, _globals, _track_id, _opts),
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
            melisma_flag: Syllable.flagged?(note.metadata),
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

  # 组派生挂在 ScorePlan：纯函数、确定性，组归属随音符进 plan，
  # Analysis 只做打包不重新推导。
  defp attach_groups(notes) do
    memberships =
      notes
      |> Enum.map(fn note -> {note.id, note.start_tick, note.end_tick, note.melisma_flag} end)
      |> Syllable.derive_groups()
      |> Map.new(&{&1.id, &1})

    group_sizes =
      memberships
      |> Map.values()
      |> Enum.group_by(& &1.head_id)
      |> Map.new(fn {head_id, members} -> {head_id, length(members)} end)

    Enum.map(notes, fn note ->
      membership = Map.fetch!(memberships, note.id)

      Map.merge(note, %{
        continuation?: membership.continuation?,
        head_id: membership.head_id,
        member_index: membership.member_index,
        group_size: Map.fetch!(group_sizes, membership.head_id)
      })
    end)
  end

  # 窗（或全轨）的局部时基原点：首音符起点前保留 head_padding 的辅音回排空间，
  # 之前的死区不进推理。全轨且首音符贴近 0 时 origin 为 0，保持既有语义。
  defp build_origin([]), do: {:ok, 0.0}

  defp build_origin([first | _rest]),
    do: {:ok, max(0.0, first.start_sec - @head_padding_sec)}

  defp rebase_notes(notes, origin_sec) do
    Enum.map(notes, fn note ->
      %{note | start_sec: note.start_sec - origin_sec, end_sec: note.end_sec - origin_sec}
    end)
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

  defp build_pitch_overrides(pins, notes, snapshot, origin_sec, frame_rate) do
    by_id = Map.new(notes, &{&1.id, &1})

    Enum.reduce_while(pins, {:ok, []}, fn {note_id, payload}, {:ok, acc} ->
      with {:ok, note} <- Map.fetch(by_id, note_id),
           {:ok, converted} <-
             PitchCurve.to_worker_points(payload, note, snapshot, origin_sec, frame_rate) do
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

  # 时长 pin 是音符内相对量，与 origin 无关（convert 用秒差）。生效续音音符
  # 只有一个派生延续元音（下标恒 0）；多成员组的预算校验上移到 Analysis
  # 按组总时长做（pin 可以合法地吃掉组内其他成员的区间）。
  defp convert_durations(durations, note, snapshot) when is_list(durations) do
    phoneme_count =
      cond do
        note.continuation? -> 1
        is_list(note.phonemes) -> length(note.phonemes)
        true -> nil
      end

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

  # 单音符组的预算在此兜底；多成员组的预算是组总时长，由 Analysis 在
  # G2P 填充后统一校验。
  defp validate_duration_budget(durations, %{group_size: size}) when size > 1,
    do: {:ok, durations}

  defp validate_duration_budget(durations, note) do
    pinned_seconds = Enum.sum(Enum.map(durations, fn [_index, seconds] -> seconds end))
    note_seconds = note.end_sec - note.start_sec

    if pinned_seconds <= note_seconds + 1.0e-9,
      do: {:ok, durations},
      else: {:error, {:phoneme_duration_overflow, note.id}}
  end

  defp tick_to_sec(%Snapshot{tempo_map: nil, tpqn: tpqn}, tick), do: tick / (tpqn * 2.0)

  defp tick_to_sec(%Snapshot{tempo_map: tempo_map}, tick),
    do: TempoMap.tick_to_sec(tempo_map, tick)
end

defmodule Neume.Engine.DiffSingerPipeline.Steps.Analysis do
  @moduledoc false

  # 模型级 probe：G2P（按需）+ duration/pitch 预测 + 元音锚定对齐，
  # 不跑 acoustic/vocoder。analyze 闭环在此 step 之后停机；渲染复用同一 probe。

  use Oi.Step, name: :analysis

  manifest(inputs: [:plan], outputs: [probe: :any])

  routine plan, opts do
    case probe(plan, opts) do
      {:ok, probe} -> ok(probe)
      {:error, _} = error -> error
    end
  end

  defp probe(%{notes: notes} = plan, opts) when is_list(notes) and notes != [] do
    client = Keyword.fetch!(opts, :client)
    config = Keyword.fetch!(opts, :worker_config)
    globals = plan.globals

    with {:ok, prepared} <- prepare(plan, client, config),
         :ok <- validate_group_budgets(prepared.notes, plan.duration_overrides),
         overrides <-
           attach_word_indices(
             plan.pitch_overrides ++ plan.duration_overrides,
             prepared.word_indices,
             prepared.notes
           ),
         {:ok, result} <-
           client.call(
             %{
               action: "check",
               words: prepared.words,
               globals: globals,
               overrides: overrides,
               groups: prepared.groups
             },
             config
           ),
         {:ok, boundaries} <- attach_note_ids(Map.get(result, "phonemes"), prepared.notes),
         {:ok, note_phonemes} <- note_phonemes(Map.get(result, "note_phonemes"), prepared) do
      {:ok,
       %{
         words: prepared.words,
         groups: prepared.groups,
         overrides: overrides,
         ph_dur: Map.fetch!(result, "ph_dur"),
         pitch_pred_midi: Map.fetch!(result, "pitch_pred_midi"),
         total_frames: Map.get(result, "total_frames", Enum.sum(Map.fetch!(result, "ph_dur"))),
         boundaries: boundaries,
         note_phonemes: note_phonemes,
         lead_in_sec: Map.get(result, "lead_in_sec", plan.head_padding_sec),
         origin_sec: plan.origin_sec,
         notes: Enum.map(prepared.notes, &Map.take(&1, [:id, :lyric, :language, :phonemes]))
       }}
    end
  end

  defp probe(%{notes: []}, _opts), do: {:error, :empty_score}
  defp probe(plan, _opts), do: {:error, {:invalid_score_plan, plan}}

  # G2P（按需）+ 词/组装配：probe 与挂载 probe（`DiffSingerPipeline.phonemes/3`）
  # 的共用前段。不做任何模型推理、不消费 overrides——pin 不改变音素身份，
  # 挂载时刻的有效底料等于当前 score 的物化序列（无 lyric 短路型干预）。
  @doc false
  @spec prepare(map(), module(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(%{notes: notes} = plan, client, config) when is_list(notes) and notes != [] do
    with {:ok, phonemes} <- resolve_phonemes(notes, client, config),
         notes = fill_phonemes(notes, phonemes),
         {:ok, words, word_indices} <- build_words(notes, plan.head_padding_sec) do
      {:ok,
       %{
         notes: notes,
         words: words,
         word_indices: word_indices,
         groups: build_groups(notes, word_indices)
       }}
    end
  end

  def prepare(%{notes: []}, _client, _config), do: {:error, :empty_score}
  def prepare(plan, _client, _config), do: {:error, {:invalid_score_plan, plan}}

  # worker 返回的 note_phonemes 以原 words 下标（字符串）为 key，按
  # word_indices 归并到音符 id；休止词（SP padding/gap）不在册，天然排除。
  @doc false
  @spec note_phonemes(term(), map()) :: {:ok, Neume.Identity.note_phonemes()} | {:error, term()}
  def note_phonemes(by_word, %{word_indices: word_indices}) when is_map(by_word) do
    Enum.reduce_while(word_indices, {:ok, %{}}, fn {note_id, word_index}, {:ok, acc} ->
      case Map.fetch(by_word, to_string(word_index)) do
        {:ok, sequence} when is_list(sequence) ->
          if Enum.all?(sequence, &valid_pair?/1) do
            {:cont, {:ok, Map.put(acc, note_id, sequence)}}
          else
            {:halt, {:error, {:invalid_note_phonemes, note_id, sequence}}}
          end

        {:ok, other} ->
          {:halt, {:error, {:invalid_note_phonemes, note_id, other}}}

        :error ->
          {:halt, {:error, {:missing_note_phonemes, note_id}}}
      end
    end)
  end

  def note_phonemes(other, _prepared), do: {:error, {:missing_note_phonemes, other}}

  defp valid_pair?([language, symbol]), do: is_binary(language) and is_binary(symbol)
  defp valid_pair?(_other), do: false

  # 生效续音的音素由头的元音派生（worker 侧展开），不参与 G2P。
  defp fill_phonemes(notes, resolved) do
    Enum.map(notes, fn note ->
      if note.continuation?,
        do: note,
        else: %{note | phonemes: note.phonemes || Map.fetch!(resolved, to_string(note.id))}
    end)
  end

  defp resolve_phonemes(notes, client, config) do
    missing = Enum.filter(notes, &(is_nil(&1.phonemes) and not &1.continuation?))

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

  # 组级预算：组内所有 pin 的秒数合计不得超过组总时长（pin 可以合法地
  # 吃掉组内其他成员的区间，故不能按单音符校验）。同时复核 G2P 填充后的
  # 头音符 pin 下标范围（续音的下标恒 0，ScorePlan 已校验）。
  defp validate_group_budgets(notes, duration_overrides) do
    pins_by_note = Map.new(duration_overrides, &{&1.note_id, &1.durations})
    by_id = Map.new(notes, &{&1.id, &1})

    notes
    |> Enum.group_by(& &1.head_id)
    |> Enum.reduce_while(:ok, fn {head_id, members}, :ok ->
      with :ok <- validate_pin_indices(members, pins_by_note, by_id) do
        total = members |> Enum.map(&(&1.end_sec - &1.start_sec)) |> Enum.sum()

        pinned =
          members
          |> Enum.flat_map(fn member -> Map.get(pins_by_note, member.id, []) end)
          |> Enum.map(fn [_index, seconds] -> seconds end)
          |> Enum.sum()

        if pinned <= total + 1.0e-9,
          do: {:cont, :ok},
          else: {:halt, {:error, {:phoneme_duration_overflow, head_id}}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_pin_indices(members, pins_by_note, by_id) do
    Enum.reduce_while(members, :ok, fn member, :ok ->
      durations = Map.get(pins_by_note, member.id, [])
      head = Map.fetch!(by_id, member.head_id)
      capacity = if member.continuation?, do: 1, else: length(head.phonemes || [])

      case Enum.find(durations, fn [index, _seconds] -> index >= capacity end) do
        nil -> {:cont, :ok}
        [index, _seconds] -> {:halt, {:error, {:phoneme_index_out_of_range, member.id, index}}}
      end
    end)
  end

  # 续音成员的词是空音素占位（`[[], dur, midi]`），由 worker 按 groups
  # 展开时填入头的元音；成员贴接组头，不产生 gap 休止词。
  defp build_words(notes, head_padding_sec) do
    first_language = notes |> hd() |> language_for()
    head = [[[[first_language, "SP"]], head_padding_sec, 0.0]]

    {words, indices, _previous} =
      Enum.reduce(notes, {head, %{}, nil}, fn note, {words, indices, previous} ->
        rest = gap_word(previous, note)
        word_index = length(words) + length(rest)

        word =
          if note.continuation?,
            do: [[], note.end_sec - note.start_sec, note.midi * 1.0],
            else: [note.phonemes, note.end_sec - note.start_sec, note.midi * 1.0]

        {words ++ rest ++ [word], Map.put(indices, note.id, word_index), note}
      end)

    {:ok, words, indices}
  end

  # 多成员组 → `[头词下标, 成员词下标, ...]`（成员按组内序号排序）。
  defp build_groups(notes, word_indices) do
    notes
    |> Enum.filter(& &1.continuation?)
    |> Enum.group_by(& &1.head_id)
    |> Enum.map(fn {head_id, members} ->
      [
        Map.fetch!(word_indices, head_id)
        | members
          |> Enum.sort_by(& &1.member_index)
          |> Enum.map(&Map.fetch!(word_indices, &1.id))
      ]
    end)
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

  # 续音成员的 pin 归并到头词：word 下标换头，duration 下标平移到
  # `len(头音素) + member_index - 1`（延续元音在展开词中的位置）；pitch
  # 点是绝对秒域，只换 word 下标。
  defp attach_word_indices(overrides, word_indices, notes) do
    by_id = Map.new(notes, &{&1.id, &1})

    Enum.map(overrides, fn override ->
      note = Map.fetch!(by_id, override.note_id)

      override =
        if note.continuation? do
          head = Map.fetch!(by_id, note.head_id)

          override
          |> Map.put(:note_index, Map.fetch!(word_indices, note.head_id))
          |> remap_continuation_pin(override.kind, head, note.member_index)
        else
          Map.put(override, :note_index, Map.fetch!(word_indices, note.id))
        end

      Map.delete(override, :note_id)
    end)
  end

  defp remap_continuation_pin(override, "duration", head, member_index) do
    Map.update!(override, :durations, fn durations ->
      Enum.map(durations, fn [index, seconds] ->
        [length(head.phonemes) + member_index - 1 + index, seconds]
      end)
    end)
  end

  defp remap_continuation_pin(override, _kind, _head, _member_index), do: override

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
end

defmodule Neume.Engine.DiffSingerPipeline.Steps.Synthesis do
  @moduledoc false

  # 粗粒度 worker 边界：acoustic/vocoder 的中间张量留在同一 Python 进程内。
  # step 名保持 :diffsinger，制品 reify key 不变。

  use Oi.Step, name: :diffsinger

  alias Neume.RenderArtifact

  manifest(inputs: [:plan, :probe], outputs: [artifact: :any])

  routine [plan, probe], opts do
    case render(plan, probe, opts) do
      {:ok, artifact} -> ok(artifact)
      {:error, _} = error -> error
    end
  end

  defp render(plan, probe, opts) do
    client = Keyword.fetch!(opts, :client)
    config = Keyword.fetch!(opts, :worker_config)
    globals = plan.globals

    with {:ok, out_path} <- output_path(Keyword.fetch!(opts, :output_dir)),
         {:ok, result} <-
           client.call(
             %{
               action: "render",
               words: probe.words,
               globals: globals,
               overrides: probe.overrides,
               groups: probe.groups,
               ph_dur: probe.ph_dur,
               pitch_pred_midi: probe.pitch_pred_midi,
               out_path: out_path
             },
             config
           ) do
      {:ok,
       %RenderArtifact{
         format: :wav,
         frame_count: Map.fetch!(result, "frames"),
         path: Map.fetch!(result, "path"),
         sample_rate: Map.fetch!(result, "sample_rate"),
         sample_count: Map.get(result, "samples"),
         duration_sec: Map.get(result, "duration_sec"),
         lead_in_sec: probe.lead_in_sec,
         origin_sec: plan.origin_sec,
         phonemes: probe.boundaries,
         phoneme_durations: probe.ph_dur
       }}
    end
  end

  defp output_path(directory) do
    with :ok <- File.mkdir_p(directory) do
      filename = "render_#{System.unique_integer([:positive, :monotonic])}.wav"
      {:ok, directory |> Path.join(filename) |> Path.expand()}
    end
  end
end
