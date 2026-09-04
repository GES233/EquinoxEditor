defmodule Neume.Engine.DiffSingerPipeline do
  @moduledoc """
  Neume 的真实 DiffSinger Oi 图。

  `ScorePlan` 只做轻量、确定性的 score→秒域装配（含局部时基 `origin_sec`）；
  `Analysis` 是模型级 probe（G2P + duration/pitch 预测 + 元音锚定对齐），
  不跑 acoustic/vocoder，analyze 闭环在它之后停机；`Synthesis` 是粗粒度
  worker 边界，整条 ONNX 声学管线的中间张量留在同一 Python 进程内，不跨
  Orchid step、进程邮箱或 ETS 搬运。
  """

  alias Coconut.Render.Engine.Snapshot
  alias Neume.Analysis
  alias Neume.Engine.DiffSingerPipeline.Steps
  alias Neume.Engine.DiffSingerWorker
  alias Neume.Voicebank.DiffSinger
  alias Oi.Flowgraph

  @type state :: %{
          compiled: Oi.Compiled.t(),
          compiled_analysis: Oi.Compiled.t(),
          client: module(),
          worker_config: map(),
          globals: %{String.t() => term()},
          output_dir: Path.t(),
          manifest: DiffSinger.t(),
          cache: boolean()
        }

  @spec compile(keyword()) :: {:ok, state()} | {:error, term()}
  def compile(opts) when is_list(opts) do
    manifest = Keyword.fetch!(opts, :manifest)
    track_id = Keyword.fetch!(opts, :track_id)
    output_dir = Keyword.get(opts, :output_dir, Path.join(File.cwd!(), "tmp/neume-renders"))
    client = Keyword.get(opts, :client, DiffSingerWorker)

    worker_config =
      opts
      |> Keyword.get(:client_config, %{})
      |> Map.merge(%{
        voicebank_root: manifest.root,
        voicebank_digest: manifest.digest,
        python: Keyword.get(opts, :python, ["python"]),
        worker: Keyword.get(opts, :worker, default_worker())
      })

    globals = %{
      "speaker" => Keyword.get(opts, :speaker, default_speaker(manifest)),
      "gender" => Keyword.get(opts, :gender, 0.0),
      "velocity" => Keyword.get(opts, :velocity, 1.0),
      "depth" => Keyword.get(opts, :depth, 0.6),
      "steps" => Keyword.get(opts, :steps, 20)
    }

    graph =
      Flowgraph.new_flowchart()
      |> Flowgraph.add_step(Steps.ScorePlan, opts: [track_id: track_id])
      |> Flowgraph.add_step(Steps.Analysis,
        opts: [client: client, worker_config: worker_config, globals: globals]
      )
      |> Flowgraph.add_step(Steps.Synthesis,
        opts: [
          client: client,
          worker_config: worker_config,
          output_dir: output_dir,
          globals: globals
        ]
      )
      |> Flowgraph.connect({:score_plan, :plan}, {:analysis, :plan})
      |> Flowgraph.connect({:score_plan, :plan}, {:diffsinger, :plan})
      |> Flowgraph.connect({:analysis, :probe}, {:diffsinger, :probe})

    # 同一 cluster 内 Oi 不分 stage，checkpoint 无法停在 Synthesis 前；
    # analyze 闭环用独立的 Analysis-only 图。
    analysis_graph =
      Flowgraph.new_flowchart()
      |> Flowgraph.add_step(Steps.ScorePlan, opts: [track_id: track_id])
      |> Flowgraph.add_step(Steps.Analysis,
        opts: [client: client, worker_config: worker_config, globals: globals]
      )
      |> Flowgraph.connect({:score_plan, :plan}, {:analysis, :plan})

    with {:ok, compiled} <- Oi.compile(graph),
         {:ok, compiled_analysis} <- Oi.compile(analysis_graph) do
      {:ok,
       %{
         compiled: compiled,
         compiled_analysis: compiled_analysis,
         client: client,
         worker_config: worker_config,
         globals: globals,
         output_dir: output_dir,
         manifest: manifest,
         cache: Keyword.get(opts, :cache, true)
       }}
    end
  end

  @spec engine_config(state(), term()) :: map()
  def engine_config(%{compiled: compiled}, _track_id) do
    %{
      compiled: compiled,
      port_map: %{
        duration: {:input, :score_plan, :duration_pins},
        pitch: {:input, :score_plan, :pitch_pins}
      },
      base_data: fn snapshot ->
        %{score_plan: %{snapshot: snapshot, duration_pins: %{}, pitch_pins: %{}}}
      end
    }
  end

  @doc """
  只跑 `ScorePlan → Analysis` 的 analyze/align 闭环：独立编译图，
  返回不产出音频的 `Neume.Analysis`。
  """
  @spec analyze(state(), Snapshot.t(), %{pitch: map(), duration: map()}, term()) ::
          {:ok, Analysis.t()} | {:error, term()}
  def analyze(%{} = state, %Snapshot{} = snapshot, pins, _track_id) do
    data = %{
      score_plan: %{
        snapshot: snapshot,
        pitch_pins: Map.get(pins, :pitch, %{}),
        duration_pins: Map.get(pins, :duration, %{})
      }
    }

    with {:ok, result} <- Oi.execute(state.compiled_analysis, data: data),
         {:ok, probe} <- Oi.Result.reify(result, {:analysis, :probe}) do
      {:ok, to_analysis(probe, state.manifest)}
    end
  end

  @doc """
  挂载/重挂 probe：G2P + 组展开的轻量路径（worker `expand`，不跑模型），
  返回 probe 物化的逐音符词内音素序列——pin 身份底料（`Neume.Identity`）。
  不经过 Oi 图，直接复用 step 的纯装配函数。
  """
  @spec phonemes(state(), Snapshot.t(), term()) ::
          {:ok, Neume.Identity.note_phonemes()} | {:error, term()}
  def phonemes(%{} = state, %Snapshot{} = snapshot, track_id) do
    with {:ok, plan} <- Steps.ScorePlan.build(snapshot, %{}, %{}, track_id),
         {:ok, prepared} <- Steps.Analysis.prepare(plan, state.client, state.worker_config),
         {:ok, result} <-
           state.client.call(
             %{action: "expand", words: prepared.words, groups: prepared.groups},
             state.worker_config
           ),
         {:ok, sequences} <-
           Steps.Analysis.note_phonemes(Map.get(result, "note_phonemes"), prepared) do
      {:ok, sequences}
    end
  end

  @doc """
  窗口化增量渲染：分窗 → 逐窗查缓存（miss 才走 Oi 全图推理）→ 按绝对
  采样偏移拼接。全局帧约定与旧整轨渲染一致：音频 t=0 ↔ 歌曲绝对
  `-head_padding`，窗局部帧平移量为 `round(origin_sec * frame_rate)`。
  """
  @spec render(state(), Snapshot.t(), %{pitch: map(), duration: map()}, term()) ::
          {:ok, Neume.RenderArtifact.t()} | {:error, term()}
  def render(%{} = state, %Snapshot{} = snapshot, pins, track_id) do
    with {:ok, view} <- fetch_vocal_view(snapshot, track_id),
         {:ok, windows} <- split_windows(view, snapshot.tpqn),
         {:ok, results} <- render_windows(state, snapshot, view, track_id, windows, pins) do
      assemble(state, windows, results)
    end
  end

  @spec fetch_artifact(Oi.Result.t()) :: {:ok, Neume.RenderArtifact.t()} | {:error, term()}
  def fetch_artifact(%Oi.Result{} = result) do
    Oi.Result.reify(result, {:diffsinger, :artifact})
  end

  defp fetch_vocal_view(%Snapshot{tracks: tracks}, track_id) do
    case Map.fetch(tracks, track_id) do
      {:ok, %{module: Coconut.Edit.Track.Vocal} = view} -> {:ok, view}
      {:ok, %{module: module}} -> {:error, {:not_vocal_track, track_id, module}}
      :error -> {:error, {:unknown_track, track_id}}
    end
  end

  defp split_windows(%{elements: []}, _tpqn), do: {:error, :empty_score}

  defp split_windows(%{elements: elements}, tpqn) do
    items = Enum.map(elements, fn {id, _note, span} -> {id, span} end)
    {:ok, Neume.Windowing.split(items, tpqn: tpqn)}
  end

  defp render_windows(state, snapshot, view, track_id, windows, pins) do
    Enum.reduce_while(windows, {:ok, []}, fn window, {:ok, acc} ->
      case render_window(state, snapshot, view, track_id, window, pins) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _} = error -> error
    end
  end

  defp render_window(state, snapshot, view, track_id, window, pins) do
    note_ids = MapSet.new(window.note_ids)

    elements =
      Enum.filter(view.elements, fn {id, _note, _span} -> MapSet.member?(note_ids, id) end)

    window_snapshot = put_window_elements(snapshot, track_id, view, elements)

    window_pins = %{
      pitch: Map.take(Map.get(pins, :pitch, %{}), window.note_ids),
      duration: Map.take(Map.get(pins, :duration, %{}), window.note_ids)
    }

    key =
      Neume.RenderCache.key(%{
        voicebank_digest: state.manifest.digest,
        globals: state.globals,
        notes: Enum.map(elements, &canonical_note/1),
        pins: window_pins,
        tempo_map: snapshot.tempo_map,
        tpqn: snapshot.tpqn
      })

    cache_dir = cache_dir(state)

    with :skip <- cache_fetch(state, cache_dir, key),
         {:ok, result} <- execute_window(state, window_snapshot, window_pins) do
      cache_store(state, cache_dir, key, result)
    else
      {:hit, entry} -> hit_result(entry)
      {:error, _} = error -> error
    end
  end

  defp put_window_elements(%Snapshot{} = snapshot, track_id, view, elements) do
    view = %{view | elements: elements}
    %{snapshot | tracks: Map.put(snapshot.tracks, track_id, view)}
  end

  defp canonical_note({id, note, {start_tick, end_tick}}) do
    [id, note.key, note.lyric, note.annotation, note.metadata, start_tick, end_tick]
  end

  defp cache_fetch(%{cache: false}, _dir, _key), do: :skip

  defp cache_fetch(_state, dir, key) do
    case Neume.RenderCache.fetch(dir, key) do
      {:ok, entry} -> {:hit, entry}
      :miss -> :skip
    end
  end

  defp execute_window(state, window_snapshot, window_pins) do
    data = %{
      score_plan: %{
        snapshot: window_snapshot,
        pitch_pins: window_pins.pitch,
        duration_pins: window_pins.duration
      }
    }

    with {:ok, result} <- Oi.execute(state.compiled, data: data),
         {:ok, artifact} <- Oi.Result.reify(result, {:diffsinger, :artifact}) do
      {:ok,
       %{
         cache: :miss,
         path: artifact.path,
         boundaries: artifact.phonemes,
         ph_dur: artifact.phoneme_durations,
         lead_in_sec: artifact.lead_in_sec,
         frames: artifact.frame_count,
         origin_sec: artifact.origin_sec,
         intermediate?: true
       }}
    end
  end

  defp cache_store(%{cache: false}, _dir, _key, result), do: {:ok, result}

  defp cache_store(_state, dir, key, result) do
    meta = %{
      "boundaries" => result.boundaries,
      "ph_dur" => result.ph_dur,
      "lead_in_sec" => result.lead_in_sec,
      "frames" => result.frames,
      "origin_sec" => result.origin_sec
    }

    with {:ok, entry} <- Neume.RenderCache.put(dir, key, result.path, meta),
         :ok <- File.rm(result.path) do
      {:ok, %{result | path: entry.path}}
    end
  end

  defp hit_result(entry) do
    meta = entry.meta

    with {:ok, boundaries} <- decode_boundaries(Map.get(meta, "boundaries")) do
      {:ok,
       %{
         cache: :hit,
         path: entry.path,
         boundaries: boundaries,
         ph_dur: Map.get(meta, "ph_dur", []),
         lead_in_sec: Map.get(meta, "lead_in_sec", 0.5),
         frames: Map.get(meta, "frames", 0),
         origin_sec: Map.get(meta, "origin_sec", 0.0),
         intermediate?: false
       }}
    end
  end

  defp decode_boundaries(boundaries) when is_list(boundaries) do
    Enum.reduce_while(boundaries, {:ok, []}, fn boundary, {:ok, acc} ->
      case boundary do
        %{
          "language" => language,
          "symbol" => symbol,
          "start_frame" => start_frame,
          "end_frame" => end_frame,
          "phoneme_index" => phoneme_index
        } ->
          {:cont,
           {:ok,
            [
              %{
                language: language,
                symbol: symbol,
                type: Map.get(boundary, "type"),
                start_frame: start_frame,
                end_frame: end_frame,
                note_id: Map.get(boundary, "note_id"),
                phoneme_index: phoneme_index
              }
              | acc
            ]}}

        _other ->
          {:halt, {:error, {:invalid_cached_boundary, boundary}}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _} = error -> error
    end
  end

  defp decode_boundaries(other), do: {:error, {:invalid_cached_boundaries, other}}

  defp assemble(state, windows, results) do
    sample_rate = state.manifest.timing.sample_rate
    frame_rate = state.manifest.timing.frame_rate

    with {:ok, items} <- read_clips(results, sample_rate),
         {:ok, mixed} <- Neume.Wav.concat(items, sample_rate),
         {:ok, out_path} <- output_path(state.output_dir),
         :ok <- Neume.Wav.write(out_path, mixed.samples, sample_rate) do
      boundaries =
        results
        |> Enum.flat_map(fn result ->
          shift = round(result.origin_sec * frame_rate)

          Enum.map(result.boundaries, fn boundary ->
            %{
              boundary
              | start_frame: boundary.start_frame + shift,
                end_frame: boundary.end_frame + shift
            }
          end)
        end)

      {:ok,
       %Neume.RenderArtifact{
         format: :wav,
         frame_count: round(mixed.sample_count * frame_rate / sample_rate),
         path: out_path,
         sample_rate: sample_rate,
         sample_count: mixed.sample_count,
         duration_sec: mixed.sample_count / sample_rate,
         lead_in_sec: results |> List.first() |> Map.get(:lead_in_sec),
         phonemes: boundaries,
         phoneme_durations: Enum.flat_map(results, & &1.ph_dur),
         windows:
           Enum.zip_with(windows, results, fn window, result ->
             %{
               start_tick: window.start_tick,
               end_tick: window.end_tick,
               note_ids: window.note_ids,
               cache: result.cache
             }
           end)
       }}
    end
  end

  defp read_clips(results, sample_rate) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      case Neume.Wav.read(result.path) do
        {:ok, clip} ->
          {:cont, {:ok, [%{clip: clip, offset: round(result.origin_sec * sample_rate)} | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:window_audio_unreadable, result.path, reason}}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _} = error -> error
    end
  end

  defp cache_dir(state), do: Path.join(state.output_dir, "cache")

  defp output_path(directory) do
    with :ok <- File.mkdir_p(directory) do
      filename = "render_#{System.unique_integer([:positive, :monotonic])}.wav"
      {:ok, directory |> Path.join(filename) |> Path.expand()}
    end
  end

  defp to_analysis(probe, %DiffSinger{} = manifest) do
    %Analysis{
      notes: probe.notes,
      phonemes: probe.boundaries,
      phoneme_durations: probe.ph_dur,
      pitch_pred_midi: probe.pitch_pred_midi,
      note_phonemes: probe.note_phonemes,
      lead_in_sec: probe.lead_in_sec,
      origin_sec: probe.origin_sec,
      total_frames: probe.total_frames,
      frame_rate: manifest.timing.frame_rate,
      sample_rate: manifest.timing.sample_rate,
      hop_size: manifest.timing.hop_size
    }
  end

  defp default_worker, do: Application.app_dir(:neume, "priv/diffsinger/worker.py")

  defp default_speaker(%DiffSinger{speakers: speakers}) do
    if Map.has_key?(speakers, "Normal"), do: "Normal", else: speakers |> Map.keys() |> hd()
  end
end
