defmodule EquinoxAdapters.DiffSingerE2ETest do
  @moduledoc """
  真引擎 e2e：edit → adopt → dispatch → check → sidecar 推理 → wav artifact。

  需要本机存在 Qixuan DiffSinger 声库（`EQUINOX_DS_VB` 环境变量覆盖
  默认路径）与 `uv`。默认排除（`@tag :real_engine`），手动跑：

      mix test --include real_engine
  """

  use ExUnit.Case, async: false

  # 真引擎用例含 sidecar 冷启动（uv 依赖解析 + 8 session 加载）与 CPU 扩散
  # 推理，远超 60s 默认上限
  @moduletag timeout: 900_000

  alias Coconut.Edit.{Command, History, Operations.InsertNote}
  alias Coconut.Score.Key.TwelveET
  alias Coconut.Util.ID

  alias Equinox.Kernel.{Blackboard, Graph, Runner}
  alias Equinox.Kernel.Graph.Node
  alias Equinox.Session.Context
  alias EquinoxAdapters.DiffSinger.{InferStep, Sidecar}
  alias EquinoxAdapters.UTAUDiffSingerCompat
  alias EquinoxDomain.Command.AdoptRequest
  alias EquinoxDomain.Port.Channels.PhonemeTiming
  alias EquinoxDomain.Score.{Project, TrackMeta}

  @default_vb "E:/ProgramAssets/OpenUTAUSingers/Qixuan_v2.5.0_DiffSinger_OpenUtau"

  @tag :real_engine
  test "音符 → sidecar 五段推理 → wav artifact 落黑板" do
    model_root = System.get_env("EQUINOX_DS_VB") || @default_vb

    unless File.dir?(model_root) do
      raise "DiffSinger 声库目录不存在：#{model_root}（用 EQUINOX_DS_VB 指定）"
    end

    session_id = "ds-e2e-#{System.unique_integer([:positive])}"
    assert {:ok, _pid} = Oi.Runtime.Session.ensure_started(session_id)

    on_exit(fn ->
      _ = Oi.Runtime.Session.stop(session_id)
    end)

    track_id = "track_ds"
    unit_id = {track_id, 0}

    # 1. 声库 → engines 注册表
    assert {:ok, {UTAUDiffSingerCompat, config}} = UTAUDiffSingerCompat.load(model_root)

    # 2. 工程：120bpm + 一轨三音符（音素走 metadata，两只老虎片段）
    {:ok, project} = Project.new(id: "project_ds", metadata: %{name: "DS e2e"})
    {:ok, project, _track} = Project.add_track(project, id: track_id)

    note1 = ID.generate_id("Note_")
    note2 = ID.generate_id("Note_")
    note3 = ID.generate_id("Note_")

    inserts = [
      {"global:tempo", ID.generate_id("Tempo_"), :head, {0, 480}, %{bpm: 120}},
      {track_id, note1, :head, {0, 240},
       %{
         pitch: twelve_et(60),
         lyric: "两",
         phonemes: [["zh", "l"], ["zh", "iang"]]
       }},
      {track_id, note2, note1, {240, 480},
       %{
         pitch: twelve_et(62),
         lyric: "只",
         phonemes: [["zh", "zh"], ["zh", "i"]]
       }},
      {track_id, note3, note2, {480, 960},
       %{
         pitch: twelve_et(64),
         lyric: "老",
         phonemes: [["zh", "l"], ["zh", "ao"]]
       }}
    ]

    {:ok, project} = apply_inserts(project, inserts)
    project = put_voicebank(project, track_id, "qixuan")

    # 3. adopt：:phoneme_timing patch（盖引擎版本戳）→ History 挂载
    payload = %{
      phonemes: [
        %{lang: "zh", symbol: "l", start_frame: 40, end_frame: 50, note_index: 0},
        %{lang: "zh", symbol: "iang", start_frame: 50, end_frame: 92, note_index: 0}
      ],
      lead_in_sec: 0.5
    }

    {:ok, patch} =
      AdoptRequest.build_patch(project.workspace, PhonemeTiming, %{
        track_id: track_id,
        anchor: {:ordinal, [note1]},
        payload: payload,
        engine: UTAUDiffSingerCompat.engine_key(config)
      })

    {:ok, project, _mounted} = attach(project, patch)

    # 4. dispatch（手工图：:infer 节点 = InferStep，words 端口由 spec target 喂）
    out_dir = Path.join(System.tmp_dir!(), "ds_e2e_#{System.unique_integer([:positive])}")

    ctx =
      Context.new(session_id, project, engines: %{"qixuan" => {UTAUDiffSingerCompat, config}})
      |> then(fn ctx -> %{ctx | graphs: %{track_id => infer_graph(model_root, out_dir)}} end)

    {_ctx, dispatch} = Context.prepare_dispatch(ctx)

    # 5. check → render（直调 Runner，绕开 Server.dispatch 的 log-only 失败路径）
    assert {:ok, board} = Runner.run(dispatch, Blackboard.new())

    unit_outputs = Blackboard.fetch_via_segment(board, unit_id)

    assert %{path: path, sample_rate: 44_100, frames: frames, lead_in_sec: 0.5} =
             unit_outputs[{unit_id, "infer|audio"}]

    assert frames > 0
    assert File.exists?(path)
    assert Path.basename(path) == "track_ds_0.wav"
  end

  @tag :real_engine
  test "align：元音锚点 + 首辅音提前 + 对齐回放渲染" do
    model_root = System.get_env("EQUINOX_DS_VB") || @default_vb

    unless File.dir?(model_root) do
      raise "DiffSinger 声库目录不存在：#{model_root}（用 EQUINOX_DS_VB 指定）"
    end

    out_dir = Path.join(System.tmp_dir!(), "ds_align_#{System.unique_integer([:positive])}")
    {:ok, sidecar} = Sidecar.ensure_started(model_root, out_dir: out_dir)

    # 120bpm 三音符（同主 e2e 夹具）：词槽 0.5/0.25/0.25/0.5s
    words = [
      [[["zh", "SP"]], 0.5, 0],
      [[["zh", "l"], ["zh", "iang"]], 0.25, 60.0],
      [[["zh", "zh"], ["zh", "i"]], 0.25, 62.0],
      [[["zh", "l"], ["zh", "ao"]], 0.5, 64.0]
    ]

    frame_rate = 44_100 / 512
    anchor0 = round(0.5 * frame_rate)

    assert {:ok, aligned} = Sidecar.align(sidecar, words)

    assert %{phonemes: phonemes, ph_dur: ph_dur, lead_in_sec: lead_in, total_frames: total} =
             aligned

    # lead_in = padding；total = 全部词槽
    assert_in_delta lead_in, 0.5, 0.01
    assert_in_delta total, 1.5 * frame_rate, 1.0
    assert Enum.sum(ph_dur) == total

    # 边界单调连续
    Enum.reduce(phonemes, 0, fn ph, prev ->
      assert ph.start_frame == prev
      assert ph.end_frame > ph.start_frame or ph.symbol == "SP"
      ph.end_frame
    end)

    # 句首 SP 无 note_index；首辅音 l 提前到音符起点之前
    assert hd(phonemes).symbol == "SP" and hd(phonemes).note_index == nil
    first_l = Enum.find(phonemes, &(&1.symbol == "l"))
    first_iang = Enum.find(phonemes, &(&1.symbol == "iang"))
    assert first_l.end_frame == first_iang.start_frame
    assert first_l.start_frame < anchor0
    # 元音 onset = 音符起点（±1 帧）
    assert_in_delta first_iang.start_frame, anchor0, 1

    # 对齐回放：aligned ph_dur 走 override，artifact 与 align 一致
    out_path = Path.join(out_dir, "aligned.wav")

    assert {:ok, artifact} =
             Sidecar.render(sidecar, words,
               out_path: out_path,
               seed: 42,
               ph_dur_override: ph_dur,
               lead_in_sec: lead_in
             )

    assert artifact.lead_in_sec == lead_in
    assert artifact.frames == total
    assert File.exists?(out_path)
  end

  # ---- 夹具（风格同 kernel EngineAdapterTest） ----

  defp infer_graph(model_root, out_dir) do
    Graph.new()
    |> Graph.add_node(%Node{
      id: :infer,
      container: InferStep,
      inputs: [:words],
      outputs: [:audio],
      options: [model_root: model_root, out_dir: out_dir, seed: 42]
    })
  end

  defp put_voicebank(%Project{} = project, track_id, voicebank_id) do
    {:ok, meta} = Project.track_meta(project, track_id)
    {:ok, meta} = TrackMeta.update(meta, voicebank_id: voicebank_id)
    {:ok, project} = Project.put_track_meta(project, track_id, meta)
    project
  end

  defp attach(%Project{} = project, patch) do
    hist = History.new(project.workspace)
    {:ok, hist} = History.run(hist, Command.attach_patches([patch]))
    project = %{project | workspace: History.current(hist).workspace}
    {:ok, track} = Project.fetch_track(project, patch.track_id)
    [mounted] = track.patches
    {:ok, project, mounted}
  end

  defp apply_inserts(%Project{} = project, inserts) do
    hist = History.new(project.workspace)

    Enum.reduce_while(inserts, {:ok, hist}, fn {track_id, note_id, after_id, span, attrs},
                                               {:ok, hist} ->
      req = %InsertNote{
        track_id: track_id,
        note_id: note_id,
        after_id: after_id,
        span: span,
        attrs: attrs
      }

      case History.apply(hist, req) do
        {:ok, hist} -> {:cont, {:ok, hist}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, hist} -> {:ok, %{project | workspace: History.current(hist).workspace}}
      {:error, _} = err -> err
    end
  end

  defp twelve_et(midi) do
    {:ok, key} = TwelveET.new(midi)
    key
  end
end
