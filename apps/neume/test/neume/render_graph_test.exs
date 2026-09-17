defmodule Neume.RenderGraphTest do
  @moduledoc """
  多轨渲染图（`Neume.RenderGraph`）：solo/mute 路由矩阵、track 级
  fan-out 结构、混音制品输出、失败聚合与 mix/master 节点缓存
  （orchid_stratum）行为。
  """

  use ExUnit.Case, async: true

  alias Coconut.Edit.{Track, Workspace}
  alias Coconut.Project
  alias Neume.Engine.WavMockPipeline
  alias Neume.{MixPipeline, MultiTrack, TrackConfig, TrackRuntime}
  alias Neume.Voicebank.Registry

  @channels %{duration: Neume.Channels.DurationPin, pitch: Neume.Channels.PitchPin}

  # 与 `Neume.MultiTrackNotePhonemesTest` 同款手法：直接构造挂
  # WavMockPipeline 的 MultiTrack 值（mock 无声库，不走 open/2 的声库解析）。
  defp mock_runtime(track_ids) do
    tracks =
      Map.new(track_ids, fn track_id ->
        {:ok, track} = Track.new(%{id: track_id, module: Track.Vocal})
        {track_id, track}
      end)

    {:ok, workspace} = Workspace.new(%{id: "ws-render-graph", tracks: tracks})

    {:ok, project} =
      Project.new(%{
        id: "project-render-graph",
        workspace: workspace,
        voicebank: nil,
        metadata: %{}
      })

    {:ok, session} = Coconut.new(project, channels: @channels)
    {:ok, mix_pipeline} = Neume.MixPipeline.compile(output_dir: "tmp/neume-test")

    runtimes =
      Map.new(track_ids, fn track_id ->
        {:ok, state} = WavMockPipeline.compile(ticks_per_frame: 10)

        {track_id,
         %TrackRuntime{
           track_id: track_id,
           voicebank: nil,
           pipeline: WavMockPipeline,
           pipeline_state: state,
           engine: {CoconutOi.OrchidAdapter, WavMockPipeline.engine_config(state, track_id)},
           channels: @channels,
           interventions: %{}
         }}
      end)

    %MultiTrack{
      session: session,
      pickle_registry: Coconut.Pickle.Track.default_registry(),
      voicebank_registry: %Registry{entries: %{}, diagnostics: []},
      tracks: runtimes,
      mix_pipeline: mix_pipeline,
      output_dir: "tmp/neume-test",
      open_opts: [],
      cache_stores: Neume.RenderGraph.new_cache_stores()
    }
  end

  defp insert_note(runtime, track_id, note_id, attrs) do
    {:ok, runtime} = MultiTrack.insert_note(runtime, track_id, note_id, :head, {0, 480}, attrs)
    runtime
  end

  defp audible_ids(runtime) do
    {:ok, project} = Coconut.project(runtime.session)
    MixPipeline.audible_tracks(project.workspace.tracks)
  end

  # ---------- solo/mute 路由 ----------

  test "audible_tracks：无 solo 取全部非 mute 轨并按 id 排序" do
    tracks =
      Map.new(["b", "a", "c"], fn id ->
        {:ok, track} = Track.new(%{id: id, module: Track.Vocal})
        {id, track}
      end)

    assert Enum.map(MixPipeline.audible_tracks(tracks), &elem(&1, 0)) == ["a", "b", "c"]

    {:ok, muted} = TrackConfig.put_mix(tracks["b"], %{mute: true})
    tracks = %{tracks | "b" => muted}
    assert Enum.map(MixPipeline.audible_tracks(tracks), &elem(&1, 0)) == ["a", "c"]
  end

  test "audible_tracks：有 solo 时只留 solo 且非 mute 的轨" do
    tracks =
      Map.new(["a", "b"], fn id ->
        {:ok, track} = Track.new(%{id: id, module: Track.Vocal})
        {id, track}
      end)

    {:ok, soloed} = TrackConfig.put_mix(tracks["b"], %{solo: true})
    tracks = %{tracks | "b" => soloed}
    assert Enum.map(MixPipeline.audible_tracks(tracks), &elem(&1, 0)) == ["b"]

    # solo + mute 同时成立时被排除。
    {:ok, solo_muted} = TrackConfig.put_mix(tracks["b"], %{mute: true})
    tracks = %{tracks | "b" => solo_muted}
    assert MixPipeline.audible_tracks(tracks) == []
  end

  test "validate_mix 接受 legacy 三键 map（补 solo: false），拒绝非法值" do
    assert :ok = TrackConfig.validate_mix(%{gain: 1.0, pan: 0.0, mute: false})
    assert :ok = TrackConfig.validate_mix(%{gain: 1.0, pan: 0.0, mute: false, solo: true})

    assert {:error, {:invalid_mix, _}} =
             TrackConfig.validate_mix(%{gain: -1, pan: 0.0, mute: false})

    assert {:error, {:invalid_mix, _}} =
             TrackConfig.validate_mix(%{gain: 1.0, pan: 0.0, mute: false, solo: 1})
  end

  # ---------- 渲染图结构 ----------

  test "渲染图：track 节点同 stage、独立 cluster（可并行 fan-out）" do
    runtime =
      mock_runtime(["lead", "harmony"])
      |> insert_note("lead", "n1", %{pitch: 60, lyric: "la"})
      |> insert_note("harmony", "h1", %{pitch: 55, lyric: "mi"})

    assert {:ok, compiled} = Neume.RenderGraph.build(audible_ids(runtime))

    assert [stage0 | rest] = compiled.plan.stages
    assert length(stage0.tasks) == 2

    assert Enum.map(stage0.tasks, & &1.cluster) |> Enum.sort() ==
             [:render_harmony, :render_lead]

    # 下游 collect → gain/pan → mix → master → export 全部覆盖（barrier 链）。
    downstream_ids =
      rest
      |> Enum.flat_map(fn stage -> Enum.flat_map(stage.tasks, & &1.node_ids) end)
      |> Enum.sort()

    assert downstream_ids == [:collect, :export, :master, :mix, :track_gain_pan]
  end

  # ---------- 渲染与混音 ----------

  test "双轨渲染出混音制品，两轨都进入 Mix" do
    runtime =
      mock_runtime(["lead", "harmony"])
      |> insert_note("lead", "n1", %{pitch: 60, lyric: "la"})
      |> insert_note("harmony", "h1", %{pitch: 55, lyric: "mi"})

    assert {:ok, _runtime, %Neume.MixArtifact{} = artifact} = MultiTrack.render(runtime)
    assert Enum.sort(artifact.track_ids) == ["harmony", "lead"]
    assert artifact.sample_rate == 44_100
    assert File.exists?(artifact.path)
  end

  test "solo 只把 solo 轨送进 Mix；被排除轨不渲染" do
    runtime =
      mock_runtime(["lead", "harmony"])
      |> insert_note("lead", "n1", %{pitch: 60, lyric: "la"})
      |> insert_note("harmony", "h1", %{pitch: 55, lyric: "mi"})

    assert {:ok, runtime} = MultiTrack.put_mix(runtime, "lead", %{solo: true})
    assert Enum.map(audible_ids(runtime), &elem(&1, 0)) == ["lead"]

    assert {:ok, _runtime, %Neume.MixArtifact{} = artifact} = MultiTrack.render(runtime)
    assert artifact.track_ids == ["lead"]
  end

  test "被排除轨的编辑错误不阻塞渲染（跳过 check 与 render）" do
    runtime =
      mock_runtime(["lead", "broken"])
      |> insert_note("lead", "n1", %{pitch: 60, lyric: "la"})

    # broken 轨有无歌词音符：被 solo 排除后不 check、不渲染。
    {:ok, runtime} =
      MultiTrack.insert_note(runtime, "broken", "b1", :head, {0, 480}, %{pitch: 62})

    {:ok, runtime} = MultiTrack.put_mix(runtime, "lead", %{solo: true})

    assert {:ok, _runtime, %Neume.MixArtifact{track_ids: ["lead"]}} =
             MultiTrack.render(runtime)

    # 取消 solo 后错误重新参与 check 并聚合报告。
    {:ok, runtime} = MultiTrack.put_mix(runtime, "lead", %{solo: false})
    assert {:error, {:check_failed, entries}} = MultiTrack.render(runtime)
    assert Enum.any?(entries, &(&1.track_id == "broken"))
  end

  test "全部轨被排除时返回 :no_audible_tracks" do
    runtime =
      mock_runtime(["lead"])
      |> insert_note("lead", "n1", %{pitch: 60, lyric: "la"})

    {:ok, runtime} = MultiTrack.put_mix(runtime, "lead", %{mute: true})
    assert {:error, :no_audible_tracks} = MultiTrack.render(runtime)
  end

  # ---------- 节点缓存 ----------

  test "连续两次渲染：内容不变则混音链命中缓存，Export 不重写文件" do
    runtime =
      mock_runtime(["lead", "harmony"])
      |> insert_note("lead", "n1", %{pitch: 60, lyric: "la"})
      |> insert_note("harmony", "h1", %{pitch: 55, lyric: "mi"})

    assert {:ok, runtime, artifact1} = MultiTrack.render(runtime)

    {_, meta_ref} = runtime.cache_stores.meta_store
    assert :ets.info(meta_ref, :size) > 0

    assert {:ok, _runtime, artifact2} = MultiTrack.render(runtime)
    assert artifact2.path == artifact1.path
  end

  test "改 gain 后重渲：混音链缓存失效，导出新文件" do
    runtime =
      mock_runtime(["lead"])
      |> insert_note("lead", "n1", %{pitch: 60, lyric: "la"})

    assert {:ok, runtime, artifact1} = MultiTrack.render(runtime)
    assert {:ok, runtime} = MultiTrack.put_mix(runtime, "lead", %{gain: 0.5})
    assert {:ok, _runtime, artifact2} = MultiTrack.render(runtime)
    assert artifact2.path != artifact1.path
  end

  test "solo 路由变化：混音制品随输入集合变化" do
    runtime =
      mock_runtime(["lead", "harmony"])
      |> insert_note("lead", "n1", %{pitch: 60, lyric: "la"})
      |> insert_note("harmony", "h1", %{pitch: 55, lyric: "mi"})

    assert {:ok, runtime, both} = MultiTrack.render(runtime)

    {:ok, runtime} = MultiTrack.put_mix(runtime, "lead", %{solo: true})
    assert {:ok, _runtime, soloed} = MultiTrack.render(runtime)
    assert soloed.track_ids == ["lead"]
    assert soloed.path != both.path
  end

  test "编辑音符后重渲：下游缓存全部失效" do
    runtime =
      mock_runtime(["lead"])
      |> insert_note("lead", "n1", %{pitch: 60, lyric: "la"})

    assert {:ok, runtime, artifact1} = MultiTrack.render(runtime)

    {:ok, runtime} =
      MultiTrack.edit_note(runtime, "lead", "n1", %{pitch: 62})

    assert {:ok, _runtime, artifact2} = MultiTrack.render(runtime)
    assert artifact2.path != artifact1.path
  end

  # ---------- 协作取消 ----------

  test "预取消令牌：渲染终止并归一为 :render_cancelled，不产出制品" do
    runtime =
      mock_runtime(["lead"])
      |> insert_note("lead", "n1", %{pitch: 60, lyric: "la"})

    token = Oi.CancelToken.new()
    :ok = Oi.CancelToken.cancel(token)

    assert {:error, :render_cancelled} = MultiTrack.render(runtime, cancel_token: token)

    # 令牌只随调用传递，不污染 runtime：不带令牌重渲照常出制品。
    assert {:ok, _runtime, %Neume.MixArtifact{}} = MultiTrack.render(runtime)
  end
end
