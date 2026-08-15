defmodule EquinoxAdapters.DiffSinger.Packaging do
  @moduledoc """
  窗口打包：`RenderRequest`（音符 + spans + tempo 切片）→ sidecar `words`
  线上形状 `[[phonemes, dur_sec, midi], ...]`（`phonemes = [[lang, ph], ...]`）。

  - 音素来源：`note.metadata["phonemes"]`（G2P 未接入的第一期约定），
    缺失报 `{:error, {:missing_phonemes, note_id}}`；
  - tick→秒：窗口 tempo 切片内换算（`start_sec + strategy` 局部换算，
    与 `Equinox.Kernel.CurveRaster` 同一套切片语义）；
  - 音符间隙插 SP 休止词（语言沿用前一音符首音素的语言，midi 0——
    sidecar 端把含 SP/AP 的词标成 `note_rest`）；
  - 句首插 SP padding 词（0.5s，OpenUtau 同值）——preutterance 倒推空间，
    sidecar 对齐时句首辅音组从中倒推（见 `engine.py` `_place`）。
  """

  alias Coconut.Score.{Key, Note, Tempo, TempoMap}
  alias EquinoxDomain.Command.RenderRequest

  @rest_phoneme "SP"
  # 句首 SP padding（秒）：preutterance 倒推空间（OpenUtau 同值 500ms）
  @head_padding_sec 0.5

  @doc """
  `:phoneme_timing` spec 的 arity-2 target（DiffSinger 版）：忽略 patch
  payload（delta 施加未接，v1；投影/对拍语义不变），把整个窗口打包
  扇出到 `{:port, :infer, :words}`。`timing` 为声库帧网格声明
  `%{frame_rate, hop}`。
  """
  @spec target(%{frame_rate: number(), hop: pos_integer()}) ::
          (term(), RenderRequest.t() -> [tuple()])
  def target(%{frame_rate: frame_rate, hop: hop}) do
    fn _payload, %RenderRequest{} = request ->
      case build_words(request.notes, request.tempo_segments, request.tpqn) do
        {:ok, words} ->
          [
            {{:port, :infer, :words},
             %{
               words: words,
               sample_rate: round(frame_rate * hop),
               hop_size: hop,
               frame_rate: frame_rate * 1.0,
               track_id: request.track_id,
               window_start: elem(request.time_range, 0)
             }}
          ]

        {:error, reason} ->
          raise ArgumentError, "DiffSinger 窗口打包失败：#{inspect(reason)}"
      end
    end
  end

  @doc """
  音符（带 spans）→ words。`notes` 为 RenderRequest 的
  `[{note_id, Note.t(), {start_tick, end_tick}}]`（本函数自行按 start 排序）。
  """
  @spec build_words(
          [{Note.note_id(), Note.t(), {integer(), integer()}}],
          [
            TempoMap.compiled_event()
          ],
          pos_integer()
        ) :: {:ok, list()} | {:error, term()}
  def build_words(notes, [first | _] = segments, tpqn) when is_integer(tpqn) and tpqn > 0 do
    sorted = Enum.sort_by(notes, fn {_id, _note, {start, _end}} -> start end)

    with {:ok, entries} <- map_entries(sorted) do
      words = insert_rests(entries, segments, first, tpqn)
      {:ok, prepend_head_rest(words, entries)}
    end
  end

  def build_words(_notes, [], _tpqn), do: {:error, :empty_tempo_segments}

  # ---- 音符 → 中间条目（保留 tick，供休止插入与秒换算） ----

  defp map_entries(notes) do
    Enum.reduce_while(notes, {:ok, []}, fn {id, note, {start_tick, end_tick}}, {:ok, acc} ->
      with {:ok, phonemes} <- fetch_phonemes(note, id),
           {:ok, midi} <- fetch_midi(note, id) do
        entry = %{
          phonemes: phonemes,
          midi: midi,
          start_tick: start_tick,
          end_tick: end_tick
        }

        {:cont, {:ok, [entry | acc]}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp fetch_phonemes(%Note{metadata: metadata}, id) do
    case metadata do
      %{"phonemes" => [_ | _] = phonemes} ->
        if Enum.all?(phonemes, &match?([_, _], &1)) do
          {:ok, phonemes}
        else
          {:error, {:invalid_phonemes, id}}
        end

      _absent_or_empty ->
        {:error, {:missing_phonemes, id}}
    end
  end

  defp fetch_midi(%Note{key: nil}, id), do: {:error, {:missing_key, id}}
  defp fetch_midi(%Note{key: key}, _id), do: {:ok, Key.to_midi(key)}

  # ---- 休止插入 + 线上形状（[phonemes, dur_sec, midi]） ----

  defp insert_rests(entries, segments, first, tpqn) do
    {acc, _prev} =
      Enum.map_reduce(entries, nil, fn entry, prev ->
        rests =
          case prev do
            nil ->
              []

            prev ->
              gap =
                tick_to_sec(segments, first, tpqn, entry.start_tick) -
                  tick_to_sec(segments, first, tpqn, prev.end_tick)

              if gap > 0, do: [rest_word(prev, gap)], else: []
          end

        {rests ++ [to_word(entry, segments, first, tpqn)], entry}
      end)

    Enum.concat(acc)
  end

  # 句首 SP 词（preutterance 倒推空间，OpenUtau 同值 500ms）：
  # lang 取首音符首音素的语言；空音符列表不插
  defp prepend_head_rest(words, [first_entry | _]) do
    [[lang, _] | _] = first_entry.phonemes
    [[[[lang, @rest_phoneme]], @head_padding_sec, 0] | words]
  end

  defp prepend_head_rest(words, []), do: words

  defp rest_word(prev, gap_sec) do
    [[lang, _] | _] = prev.phonemes
    [[[lang, @rest_phoneme]], Float.round(gap_sec, 6), 0]
  end

  defp to_word(entry, segments, first, tpqn) do
    start_sec = tick_to_sec(segments, first, tpqn, entry.start_tick)
    end_sec = tick_to_sec(segments, first, tpqn, entry.end_tick)
    [entry.phonemes, Float.round(end_sec - start_sec, 6), entry.midi]
  end

  # ---- 切片内 tick→秒（同 CurveRaster 语义：find_by_tick + strategy 局部换算） ----

  defp tick_to_sec(segments, first, tpqn, tick) do
    segment = find_by_tick(segments, first, tick)
    segment.start_sec + Tempo.tick_to_sec(segment.strategy, tick - segment.start_pos, tpqn)
  end

  defp find_by_tick(segments, first, tick) do
    Enum.find(segments, first, fn segment ->
      tick >= segment.start_pos and
        (not is_integer(segment.end_pos) or tick < segment.end_pos)
    end)
  end
end
