defmodule Neume.Engine.MockPipeline do
  @moduledoc """
  Neume 的固定 mock 合成图。

  图只承担闭环验收，不冒充声学模型：`ScorePlan` 把 Coconut snapshot
  规划成帧，`Pitch` 合并按音符挂载的稀疏控制点，`Acoustic` 产出稳定的
  `Neume.RenderArtifact`。将来替换真实 DiffSinger worker 时，Editor 和
  Coconut 的会话边界无需改变。

  `analyze/3` 不经过 Oi 图：按 `ticks_per_frame` 直接把音符投影成确定性
  帧边界（lyric 拆字当音素），让无声库环境也能跑通 `Editor.analyze/1`
  与 `Editor.check/1`。
  """

  alias Coconut.Render.Engine.Snapshot
  alias Neume.Analysis
  alias Neume.Engine.MockPipeline.Steps.{Acoustic, Pitch, ScorePlan}
  alias Oi.Flowgraph

  @type state :: %{compiled: Oi.Compiled.t(), ticks_per_frame: pos_integer()}

  @spec compile(keyword()) :: {:ok, state()} | {:error, term()}
  def compile(opts) when is_list(opts) do
    with {:ok, ticks_per_frame} <- fetch_ticks_per_frame(opts) do
      graph =
        Flowgraph.new_flowchart()
        |> Flowgraph.add_step(ScorePlan, opts: [ticks_per_frame: ticks_per_frame])
        |> Flowgraph.add_step(Pitch)
        |> Flowgraph.add_step(Acoustic)
        |> Flowgraph.connect({:score_plan, :plan}, {:pitch, :plan})
        |> Flowgraph.connect({:score_plan, :plan}, {:acoustic, :plan})
        |> Flowgraph.connect({:pitch, :f0_midi}, {:acoustic, :f0_midi})

      with {:ok, compiled} <- Oi.compile(graph) do
        {:ok, %{compiled: compiled, ticks_per_frame: ticks_per_frame}}
      end
    end
  end

  @spec engine_config(state(), term()) :: map()
  def engine_config(%{compiled: compiled}, track_id) do
    %{
      compiled: compiled,
      port_map: %{
        pitch: {:input, :pitch, :pins},
        duration: {:input, :score_plan, :duration_pins}
      },
      base_data: fn snapshot -> base_data(snapshot, track_id) end,
      # 与真实管线同一组全局旋钮门禁；mock 不消费，只为闭环验收透传。
      globals: Map.new([:energy, :breathiness, :voicing], &{&1, {:range, 0.0, 2.0}})
    }
  end

  @doc false
  @spec base_data(Snapshot.t(), term()) :: map()
  def base_data(%Snapshot{tracks: tracks}, track_id) do
    notes =
      case Map.fetch(tracks, track_id) do
        {:ok, %{elements: elements}} -> elements
        :error -> []
      end

    %{score_plan: %{notes: notes, duration_pins: %{}}, pitch: %{pins: %{}}}
  end

  @doc "逐乐句运行 mock analyze，并保留与真实管线一致的定位形状。"
  @spec analyze_phrases(state(), Snapshot.t(), map(), map(), term()) ::
          {:ok, [{Neume.Phrase.t(), Analysis.t()}], [map()]} | {:error, term()}
  def analyze_phrases(state, %Snapshot{} = snapshot, pins, globals, track_id) do
    with {:ok, phrases} <- Neume.Phrase.split(snapshot, track_id, pins) do
      {results, errors} =
        Enum.reduce(phrases, {[], []}, fn phrase, {results, errors} ->
          case analyze(state, phrase.snapshot, phrase.pins, globals, track_id) do
            {:ok, analysis} ->
              {[{phrase, analysis} | results], errors}

            {:error, reason} ->
              error = %{
                kind: :model,
                track_id: track_id,
                phrase_id: phrase.id,
                span: {phrase.start_tick, phrase.end_tick},
                note_ids: phrase.note_ids,
                reason: reason
              }

              {results, [error | errors]}
          end
        end)

      {:ok, Enum.reverse(results), Enum.reverse(errors)}
    end
  end

  @doc "无声库环境的确定性 analyze：音符按 ticks_per_frame 投影成帧边界。"
  @spec analyze(state(), Snapshot.t(), map(), map(), term()) ::
          {:ok, Analysis.t()} | {:error, term()}
  def analyze(
        %{ticks_per_frame: ticks_per_frame},
        %Snapshot{} = snapshot,
        _pins,
        _globals,
        track_id
      ) do
    with {:ok, view} <- Map.fetch(snapshot.tracks, track_id),
         :ok <- ensure_vocal(view) do
      build_analysis(view.elements, ticks_per_frame)
    else
      :error -> {:error, {:unknown_track, track_id}}
      {:error, _} = error -> error
    end
  end

  @doc """
  挂载/重挂 probe：mock 音素派生与 analyze 同一份纯逻辑（lyric 拆字 +
  续音取头末音素），直接作为 pin 的身份底料。
  """
  @spec phonemes(state(), Snapshot.t(), term()) ::
          {:ok, Neume.Identity.note_phonemes()} | {:error, term()}
  def phonemes(_state, %Snapshot{} = snapshot, track_id) do
    with {:ok, view} <- Map.fetch(snapshot.tracks, track_id),
         :ok <- ensure_vocal(view),
         {:ok, phonemes_by_id} <- phonemes_by_id(view.elements) do
      {:ok, phonemes_by_id}
    else
      :error -> {:error, {:unknown_track, track_id}}
      {:error, _} = error -> error
    end
  end

  @doc "整轨执行 mock 图并取出制品（mock 不做分窗与缓存；全局旋钮不消费）。"
  @spec render(state(), Snapshot.t(), map(), map(), term()) ::
          {:ok, Neume.RenderArtifact.t()} | {:error, term()}
  def render(%{compiled: compiled}, %Snapshot{} = snapshot, pins, _globals, track_id) do
    data =
      snapshot
      |> base_data(track_id)
      |> put_in([:pitch, :pins], Map.get(pins, :pitch, %{}))

    with {:ok, result} <- Oi.execute(compiled, data: data) do
      fetch_artifact(result)
    end
  end

  @spec fetch_artifact(Oi.Result.t()) ::
          {:ok, Neume.RenderArtifact.t()} | {:error, term()}
  def fetch_artifact(%Oi.Result{} = result) do
    Oi.Result.reify(result, {:acoustic, :artifact})
  end

  defp ensure_vocal(%{module: Coconut.Edit.Track.Vocal}), do: :ok
  defp ensure_vocal(%{module: module}), do: {:error, {:not_vocal_track, module}}

  # 生效续音不拆字：音素 = 头音符的末音素（mock 的"延续元音"近似），
  # lyric 也不再必需。
  defp build_analysis(elements, ticks_per_frame) do
    sorted = Enum.sort_by(elements, fn {id, _note, {start_tick, _end}} -> {start_tick, id} end)

    with {:ok, phonemes_by_id} <- phonemes_by_id(elements) do
      sorted
      |> Enum.reduce_while({:ok, [], [], [], 0}, fn {id, note, {start_tick, end_tick}},
                                                    {:ok, notes, boundaries, durations, cursor} ->
        phonemes = Map.fetch!(phonemes_by_id, id)
        frames = div(end_tick - start_tick + ticks_per_frame - 1, ticks_per_frame)
        count = length(phonemes)
        base = div(frames, count)
        rest = rem(frames, count)

        {note_boundaries, note_durations, cursor} =
          phonemes
          |> Enum.with_index()
          |> Enum.reduce({[], [], cursor}, fn {[language, symbol], index},
                                              {boundaries, durations, cursor} ->
            duration = base + if index < rest, do: 1, else: 0

            boundary = %{
              language: language,
              symbol: symbol,
              type: nil,
              start_frame: cursor,
              end_frame: cursor + duration,
              note_id: id,
              phoneme_index: index
            }

            {[boundary | boundaries], [duration | durations], cursor + duration}
          end)

        entry = %{
          id: id,
          lyric: note.lyric,
          language: Map.get(note.metadata, "language", "zh"),
          phonemes: phonemes
        }

        {:cont,
         {:ok, [entry | notes], boundaries ++ Enum.reverse(note_boundaries),
          durations ++ Enum.reverse(note_durations), cursor}}
      end)
      |> case do
        {:ok, notes, boundaries, durations, total_frames} ->
          {:ok,
           %Analysis{
             notes: Enum.reverse(notes),
             phonemes: boundaries,
             phoneme_durations: durations,
             pitch_pred_midi: [],
             note_phonemes: phonemes_by_id,
             lead_in_sec: 0.0,
             origin_sec: mock_origin_sec(sorted, ticks_per_frame),
             total_frames: total_frames,
             frame_rate: 480.0 / ticks_per_frame
           }}

        {:error, _} = error ->
          error
      end
    end
  end

  defp mock_origin_sec([{_id, _note, {start_tick, _end}} | _], _ticks_per_frame),
    do: start_tick / 480.0

  defp mock_origin_sec([], _ticks_per_frame), do: 0.0

  # 排序 + 组派生 + mock G2P：analyze 与挂载 probe 的同一份纯派生。
  defp phonemes_by_id(elements) do
    sorted = Enum.sort_by(elements, fn {id, _note, {start_tick, _end}} -> {start_tick, id} end)
    memberships = ScorePlan.memberships(sorted)
    resolve_mock_phonemes(sorted, memberships)
  end

  defp resolve_mock_phonemes(sorted, memberships) do
    Enum.reduce_while(sorted, {:ok, %{}}, fn {id, note, _span}, {:ok, acc} ->
      case Map.fetch!(memberships, id) do
        %{continuation?: true, head_id: head_id} ->
          case acc do
            %{^head_id => [_ | _] = head_phonemes} ->
              {:cont, {:ok, Map.put(acc, id, [List.last(head_phonemes)])}}

            _missing ->
              {:halt, {:error, {:missing_lyric, head_id}}}
          end

        %{continuation?: false} ->
          case mock_phonemes(note, id) do
            {:ok, phonemes} -> {:cont, {:ok, Map.put(acc, id, phonemes)}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp mock_phonemes(note, id) do
    case Map.get(note.metadata, "phonemes") do
      nil ->
        case note.lyric do
          nil ->
            {:error, {:missing_lyric, id}}

          lyric ->
            language = Map.get(note.metadata, "language", "zh")
            {:ok, Enum.map(String.graphemes(lyric), &[language, &1])}
        end

      [_ | _] = phonemes ->
        {:ok, phonemes}

      other ->
        {:error, {:invalid_phonemes, id, other}}
    end
  end

  defp fetch_ticks_per_frame(opts) do
    case Keyword.fetch(opts, :ticks_per_frame) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_ticks_per_frame, value}}
      :error -> {:error, :missing_ticks_per_frame}
    end
  end
end
