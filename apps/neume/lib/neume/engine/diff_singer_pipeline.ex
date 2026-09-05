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
  alias Neume.Engine.{DiffSingerFp, DiffSingerWorker, OrchidError}
  alias Neume.Voicebank.DiffSinger
  alias Oi.Flowgraph

  # 全局表现旋钮（会话态，直接进 render，不经 tamale patch）：variance
  # 预测曲线的乘性系数，1.0 中立。逐帧曲线干预另走 channel（§6.6 第三档）。
  @global_knobs [:energy, :breathiness, :voicing]
  @knob_spec {:range, 0.0, 2.0}

  @type state :: %{
          compiled: Oi.Compiled.t(),
          compiled_analysis: Oi.Compiled.t(),
          compiled_synthesis: Oi.Compiled.t(),
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
    python = Keyword.get(opts, :python, ["python"])

    with {:ok, fp} <- resolve_fp(manifest, client, opts) do
      worker_config =
        opts
        |> Keyword.get(:client_config, %{})
        |> Map.merge(%{
          voicebank_root: manifest.root,
          voicebank_digest: manifest.digest,
          python: python,
          worker: Keyword.get(opts, :worker, default_worker()),
          fp_manifest: fp && fp.manifest_path,
          fp_manifest_digest: fp && fp.manifest_digest,
          fp_noise_version: fp && fp.noise_version,
          seed: Keyword.get(opts, :seed, 0)
        })

      globals = %{
        "speaker" => Keyword.get(opts, :speaker, default_speaker(manifest)),
        "gender" => Keyword.get(opts, :gender, 0.0),
        "velocity" => Keyword.get(opts, :velocity, 1.0),
        "depth" => Keyword.get(opts, :depth, 0.6),
        "steps" => Keyword.get(opts, :steps, 20),
        "energy" => Keyword.get(opts, :energy, 1.0),
        "breathiness" => Keyword.get(opts, :breathiness, 1.0),
        "voicing" => Keyword.get(opts, :voicing, 1.0)
      }

      graph =
        Flowgraph.new_flowchart()
        |> Flowgraph.add_step(Steps.ScorePlan,
          opts: [track_id: track_id, globals: globals, frame_rate: manifest.timing.frame_rate]
        )
        |> Flowgraph.add_step(Steps.Analysis,
          opts: [client: client, worker_config: worker_config]
        )
        |> Flowgraph.add_step(Steps.Synthesis,
          opts: [
            client: client,
            worker_config: worker_config,
            output_dir: output_dir
          ]
        )
        |> Flowgraph.connect({:score_plan, :plan}, {:analysis, :plan})
        |> Flowgraph.connect({:score_plan, :plan}, {:diffsinger, :plan})
        |> Flowgraph.connect({:analysis, :probe}, {:diffsinger, :probe})

      # 同一 cluster 内 Oi 不分 stage，checkpoint 无法停在 Synthesis 前；
      # analyze 闭环用独立的 Analysis-only 图。
      analysis_graph =
        Flowgraph.new_flowchart()
        |> Flowgraph.add_step(Steps.ScorePlan,
          opts: [track_id: track_id, globals: globals, frame_rate: manifest.timing.frame_rate]
        )
        |> Flowgraph.add_step(Steps.Analysis,
          opts: [client: client, worker_config: worker_config]
        )
        |> Flowgraph.connect({:score_plan, :plan}, {:analysis, :plan})

      synthesis_graph =
        Flowgraph.new_flowchart()
        |> Flowgraph.add_step(Steps.Synthesis,
          opts: [client: client, worker_config: worker_config, output_dir: output_dir]
        )

      with {:ok, compiled} <- Oi.compile(graph),
           {:ok, compiled_analysis} <- Oi.compile(analysis_graph),
           {:ok, compiled_synthesis} <- Oi.compile(synthesis_graph) do
        {:ok,
         %{
           compiled: compiled,
           compiled_analysis: compiled_analysis,
           compiled_synthesis: compiled_synthesis,
           client: client,
           worker_config: worker_config,
           globals: globals,
           output_dir: output_dir,
           manifest: manifest,
           cache: Keyword.get(opts, :cache, true)
         }}
      end
    end
  end

  @doc "声库内容摘要（manifest digest）：pin 输入底料的声音库事实分量。"
  @spec voicebank_digest(state()) :: String.t()
  def voicebank_digest(%{manifest: %{digest: digest}}), do: digest

  @spec engine_config(state(), term()) :: map()
  def engine_config(%{compiled: compiled}, _track_id) do
    %{
      compiled: compiled,
      port_map: %{
        duration: {:input, :score_plan, :duration_pins},
        pitch: {:input, :score_plan, :pitch_pins}
      },
      base_data: fn snapshot ->
        %{score_plan: %{snapshot: snapshot, duration_pins: %{}, pitch_pins: %{}, globals: %{}}}
      end,
      # 全局旋钮门禁：会话 globals 只允许这三个乘性系数（0.0–2.0）。
      globals: Map.new(@global_knobs, &{&1, @knob_spec})
    }
  end

  # 会话旋钮（atom key，门禁已校验）并入编译期 globals（string key）。
  defp effective_globals(state_globals, session_globals) do
    Enum.reduce(@global_knobs, state_globals, fn key, acc ->
      case Map.fetch(session_globals, key) do
        {:ok, value} -> Map.put(acc, Atom.to_string(key), value)
        :error -> acc
      end
    end)
  end

  @doc "逐乐句执行模型 probe；全部乐句都会运行，错误带轨道、乐句和 span 定位。"
  @spec analyze_phrases(state(), Snapshot.t(), %{pitch: map(), duration: map()}, map(), term()) ::
          {:ok, [{Neume.Phrase.t(), Analysis.t(), map()}], [map()]} | {:error, term()}
  def analyze_phrases(%{} = state, %Snapshot{} = snapshot, pins, session_globals, track_id) do
    with {:ok, phrases} <- Neume.Phrase.split(snapshot, track_id, pins) do
      {results, errors} =
        Enum.reduce(phrases, {[], []}, fn phrase, {results, errors} ->
          case probe_phrase(state, phrase.snapshot, phrase.pins, session_globals) do
            {:ok, analysis, plan, probe} ->
              {[{phrase, analysis, %{plan: plan, probe: probe}} | results], errors}

            {:error, reason} ->
              {results, [phrase_error(phrase, reason) | errors]}
          end
        end)

      {:ok, Enum.reverse(results), Enum.reverse(errors)}
    end
  end

  @doc """
  只跑 `ScorePlan → Analysis` 的 analyze/align 闭环：独立编译图，
  返回不产出音频的 `Neume.Analysis`。
  """
  @spec analyze(state(), Snapshot.t(), %{pitch: map(), duration: map()}, map(), term()) ::
          {:ok, Analysis.t()} | {:error, term()}
  def analyze(%{} = state, %Snapshot{} = snapshot, pins, session_globals, _track_id) do
    with {:ok, analysis, _plan, _probe} <- probe_phrase(state, snapshot, pins, session_globals) do
      {:ok, analysis}
    end
  end

  defp probe_phrase(state, snapshot, pins, session_globals) do
    data = %{
      score_plan: %{
        snapshot: snapshot,
        pitch_pins: Map.get(pins, :pitch, %{}),
        duration_pins: Map.get(pins, :duration, %{}),
        globals: effective_globals(state.globals, session_globals)
      }
    }

    with {:ok, result} <- Oi.execute(state.compiled_analysis, data: data),
         {:ok, plan} <- Oi.Result.reify(result, {:score_plan, :plan}),
         {:ok, probe} <- Oi.Result.reify(result, {:analysis, :probe}) do
      {:ok, to_analysis(probe, state.manifest), plan, probe}
    end
  end

  @doc """
  probe 路径：G2P + 组展开的轻量路径（worker `expand`，不跑模型），
  返回物化的逐音符词内音素序列。pin 底料自 2026-09-05 起改为输入事实
  签名（`Neume.Identity`），本函数的产物只服务于 duration pin 的
  可表达性校验（re-patch）与词内下标平移，不再是签名底料。
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

  `session_globals` 是会话级全局旋钮（atom key，已过门禁），并入编译期
  globals 后同时进入窗口缓存键与 worker 调用。
  """
  @spec render_checked(
          state(),
          Snapshot.t(),
          [{Neume.Phrase.t(), Analysis.t(), map()}],
          map(),
          term()
        ) ::
          {:ok, Neume.RenderArtifact.t()} | {:error, term()}
  def render_checked(%{} = state, %Snapshot{} = snapshot, checked, session_globals, track_id) do
    globals = effective_globals(state.globals, session_globals)

    with {:ok, view} <- fetch_vocal_view(snapshot, track_id),
         windows <- Enum.map(checked, fn {phrase, _analysis, _data} -> phrase end),
         {:ok, results} <- render_checked_phrases(state, view, checked, globals) do
      assemble(state, windows, results)
    else
      {:error, reason} -> {:error, OrchidError.slim(reason)}
    end
  end

  @spec render(state(), Snapshot.t(), %{pitch: map(), duration: map()}, map(), term()) ::
          {:ok, Neume.RenderArtifact.t()} | {:error, term()}
  def render(%{} = state, %Snapshot{} = snapshot, pins, session_globals, track_id) do
    globals = effective_globals(state.globals, session_globals)

    with {:ok, view} <- fetch_vocal_view(snapshot, track_id),
         {:ok, windows} <- split_windows(view, snapshot.tpqn),
         {:ok, results} <- render_windows(state, snapshot, view, track_id, windows, pins, globals) do
      assemble(state, windows, results)
    else
      {:error, reason} -> {:error, OrchidError.slim(reason)}
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

  defp render_checked_phrases(state, view, checked, globals) do
    Enum.reduce_while(checked, {:ok, []}, fn {phrase, _analysis, data}, {:ok, acc} ->
      elements =
        Enum.filter(view.elements, fn {id, _note, _span} -> id in phrase.note_ids end)

      key = render_key(state, elements, phrase.pins, globals, phrase.snapshot)

      result =
        case cache_fetch(state, cache_dir(state), key) do
          {:hit, entry} ->
            hit_result(entry)

          :skip ->
            with {:ok, rendered} <- execute_checked_phrase(state, data.plan, data.probe) do
              cache_store(state, cache_dir(state), key, rendered)
            end
        end

      case result do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _} = error -> error
    end
  end

  defp execute_checked_phrase(state, plan, probe) do
    with {:ok, result} <-
           Oi.execute(state.compiled_synthesis,
             data: %{diffsinger: %{plan: plan, probe: probe}}
           ),
         {:ok, artifact} <- Oi.Result.reify(result, {:diffsinger, :artifact}) do
      {:ok,
       %{
         path: artifact.path,
         sample_rate: artifact.sample_rate,
         sample_count: artifact.sample_count,
         frames: artifact.frame_count,
         lead_in_sec: artifact.lead_in_sec,
         origin_sec: artifact.origin_sec,
         boundaries: artifact.phonemes,
         ph_dur: artifact.phoneme_durations,
         cache: :miss,
         intermediate?: true
       }}
    end
  end

  defp render_key(state, elements, pins, globals, snapshot) do
    Neume.RenderCache.key(%{
      voicebank_digest: state.manifest.digest,
      fp_manifest_digest: state.worker_config.fp_manifest_digest,
      fp_noise_version: state.worker_config.fp_noise_version,
      seed: state.worker_config.seed,
      globals: globals,
      notes: Enum.map(elements, &canonical_note/1),
      pins: pins,
      tempo_map: snapshot.tempo_map,
      tpqn: snapshot.tpqn
    })
  end

  defp render_windows(state, snapshot, view, track_id, windows, pins, globals) do
    Enum.reduce_while(windows, {:ok, []}, fn window, {:ok, acc} ->
      case render_window(state, snapshot, view, track_id, window, pins, globals) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _} = error -> error
    end
  end

  defp render_window(state, snapshot, view, track_id, window, pins, globals) do
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
        fp_manifest_digest: state.worker_config.fp_manifest_digest,
        fp_noise_version: state.worker_config.fp_noise_version,
        seed: state.worker_config.seed,
        globals: globals,
        notes: Enum.map(elements, &canonical_note/1),
        pins: window_pins,
        tempo_map: snapshot.tempo_map,
        tpqn: snapshot.tpqn
      })

    cache_dir = cache_dir(state)

    with :skip <- cache_fetch(state, cache_dir, key),
         {:ok, result} <- execute_window(state, window_snapshot, window_pins, globals) do
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

  defp execute_window(state, window_snapshot, window_pins, globals) do
    data = %{
      score_plan: %{
        snapshot: window_snapshot,
        pitch_pins: window_pins.pitch,
        duration_pins: window_pins.duration,
        globals: globals
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

  defp phrase_error(phrase, reason) do
    %{
      kind: :model,
      track_id: phrase.track_id,
      phrase_id: phrase.id,
      span: {phrase.start_tick, phrase.end_tick},
      note_ids: phrase.note_ids,
      reason: OrchidError.slim(reason)
    }
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

  # 真实 worker 默认 FP；注入测试 client 时保持轻量，除非调用方显式 fp: true。
  defp resolve_fp(manifest, client, opts) do
    case Keyword.get(opts, :fp, :default) do
      false ->
        {:ok, nil}

      fp when is_map(fp) ->
        {:ok, fp}

      mode when mode in [:default, true] ->
        if client == DiffSingerWorker or mode == true do
          # 手术环境需要 onnx；推理环境只需 onnxruntime，二者可独立配置。
          fp_opts = [
            python: Keyword.get(opts, :fp_python, ["python"]),
            build?: Keyword.get(opts, :fp_build, true),
            voicebank_digest: manifest.digest
          ]

          fp_opts = if opts[:fp_dir], do: Keyword.put(fp_opts, :dir, opts[:fp_dir]), else: fp_opts
          DiffSingerFp.for_voicebank(manifest.root, fp_opts)
        else
          {:ok, nil}
        end
    end
  end

  defp default_worker, do: Application.app_dir(:neume, "priv/diffsinger/worker.py")

  defp default_speaker(%DiffSinger{speakers: speakers}) do
    if Map.has_key?(speakers, "Normal"), do: "Normal", else: speakers |> Map.keys() |> hd()
  end
end
