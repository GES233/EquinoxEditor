defmodule Equinox.Kernel.EngineAdapterTest do
  use ExUnit.Case, async: false

  alias Coconut.Edit.{Command, History, Operations.InsertNote}
  alias Coconut.Score.Key.TwelveET
  alias Coconut.Util.ID

  alias Equinox.Kernel.{Blackboard, Configurator, Graph, Runner, StubEngineAdapter, Voicebank}
  alias Equinox.Kernel.Graph.Node
  alias Equinox.Session
  alias Equinox.Session.{Context, Server}
  alias EquinoxDomain.Command.{AdoptRequest, RenderRequest}
  alias EquinoxDomain.Port.Channel
  alias EquinoxDomain.Port.Channels.{Curve, PhonemeTiming}
  alias EquinoxDomain.Score.{Project, TrackMeta}

  defmodule SynthStep do
    use Oi.Step, name: :synth

    manifest(inputs: [:phoneme_timing], outputs: [audio: :map])

    routine phoneme_timing, _opts do
      ok(%{received: phoneme_timing})
    end
  end

  defmodule CurveSynthStep do
    use Oi.Step, name: :synth

    manifest(inputs: [:pitch], outputs: [audio: :map])

    routine pitch, _opts do
      ok(%{received: pitch})
    end
  end

  defp stub_config(overrides \\ %{}) do
    Map.merge(
      %{voicebank_id: "stub_vb", engine_version: "0.0.1", channels: [:phoneme_timing]},
      overrides
    )
  end

  test "Configurator 从 EngineAdapter 派生 channels（单一来源，派生者优先）" do
    config = stub_config()

    conf = Configurator.new(engine: {StubEngineAdapter, config})

    assert conf.engine == {StubEngineAdapter, config}

    assert %{phoneme_timing: %{projection: projection, target: {:port, :synth, :phoneme_timing}}} =
             conf.channels

    assert is_function(projection, 2)

    # 手工注入同 key 被派生覆盖（单一来源纪律）；异 key 保留（兼容通道）
    conf2 =
      Configurator.new(
        engine: {StubEngineAdapter, config},
        channels: %{phoneme_timing: %{projection: :fake, target: :fake}, other: :spec}
      )

    assert is_function(conf2.channels.phoneme_timing.projection, 2)
    assert conf2.channels.other == :spec

    # 无 engine 时维持纯手工注入
    assert Configurator.new(channels: %{other: :spec}).channels == %{other: :spec}
  end

  test "per-track Adapter 闭环：edit → adopt（盖版本戳）→ dispatch → check → render" do
    session_id = "engine-adapter-e2e"
    assert {:ok, _pid} = Oi.Runtime.Session.ensure_started(session_id)

    on_exit(fn ->
      _ = Oi.Runtime.Session.stop(session_id)
    end)

    track_id = "track_stub"
    unit_id = {track_id, 0}
    config = stub_config()

    {:ok, project, note1} = project_with_notes("project_stub", track_id)
    project = put_voicebank(project, track_id, "stub_vb")

    payload = %{
      phonemes: [
        %{lang: "zh", symbol: "l", start_frame: 40, end_frame: 50, note_index: 0},
        %{lang: "zh", symbol: "iang", start_frame: 50, end_frame: 92, note_index: 0}
      ],
      lead_in_sec: 0.5
    }

    # 挂载：带引擎版本戳（Server.adopt_intervention 盖戳路径的纯构造部分）
    {:ok, patch} =
      AdoptRequest.build_patch(project.workspace, PhonemeTiming, %{
        track_id: track_id,
        anchor: {:ordinal, [note1]},
        payload: payload,
        engine: StubEngineAdapter.engine_key(config)
      })

    {:ok, project, mounted} = attach(project, patch)

    ctx =
      Context.new(session_id, project, engines: %{"stub_vb" => {StubEngineAdapter, config}})
      |> then(fn ctx -> %{ctx | graphs: %{track_id => synth_graph()}} end)

    {_ctx, dispatch} = Context.prepare_dispatch(ctx)

    # per-track 粒度：dispatch 携带该轨 Adapter 派生的 channel specs
    assert %{track_channels: %{^track_id => %{phoneme_timing: _}}} = dispatch

    assert %{units: [{^unit_id, _, %RenderRequest{patches: [^mounted]}, %Oi.Compiled{}}]} =
             dispatch

    # Runner 零手工 channels：check（挂载戳 vs check 戳对拍通过）→ render → payload 到板
    assert {:ok, board} = Runner.run(dispatch, Blackboard.new())

    unit_outputs = Blackboard.fetch_via_segment(board, unit_id)
    assert unit_outputs[{unit_id, "synth|phoneme_timing"}] == payload
    assert unit_outputs[{unit_id, "synth|audio"}] == %{received: payload}
  end

  test "引擎版本升级：digest 失配判 :conflict（显式接受的最坏情形）" do
    track_id = "track_upgraded"
    config = stub_config()
    {dispatch, _mounted} = stamped_dispatch(track_id, config)

    # 渲染侧换成新版本引擎：同音符同 payload，版本戳异 → :base_changed
    upgraded = stub_config(%{engine_version: "9.9.9"})
    dispatch = put_in(dispatch, [:track_channels, track_id], StubEngineAdapter.channels(upgraded))

    assert {:error, {:check_failed, [entry]}} = Runner.run(dispatch, Blackboard.new())
    assert entry.unit_id == {track_id, 0}
    assert entry.channel == :phoneme_timing
    assert entry.kind == :conflict
    assert entry.reason == :base_changed
  end

  test "capabilities 门控：Adapter 不供给的 channel → :unknown_channel 响亮失败" do
    track_id = "track_gated"
    config = stub_config()
    {dispatch, _mounted} = stamped_dispatch(track_id, config)

    # 声库声明不支持任何 channel（capabilities 收缩）→ 既有 patch 无 spec 可 resolve
    gated = StubEngineAdapter.channels(stub_config(%{channels: []}))
    assert gated == %{}
    dispatch = put_in(dispatch, [:track_channels, track_id], gated)

    assert {:error, {:check_failed, [entry]}} = Runner.run(dispatch, Blackboard.new())
    assert entry.channel == :phoneme_timing
    assert entry.kind == :unknown_channel
    assert entry.reason == :no_channel_spec
  end

  test "未知声库 id：prepare_dispatch 响亮报错且 ctx 不变" do
    track_id = "track_ghost"
    {:ok, project, _note1} = project_with_notes("project_ghost", track_id)
    project = put_voicebank(project, track_id, "ghost_vb")

    ctx = Context.new("engine-adapter-ghost", project, engines: %{})

    assert {^ctx, {:error, {:unknown_voicebank, "ghost_vb"}}} = Context.prepare_dispatch(ctx)
  end

  test "Server：engines 注入 + update_track_voicebank + adopt_intervention 盖版本戳" do
    session_id = "engine-adapter-server"
    track_id = "track_srv"
    config = stub_config()

    {:ok, project, note1} = project_with_notes("project_adapter_server", track_id)

    start_supervised!(
      Server.child_spec(
        session_id: session_id,
        name: Session.server(session_id),
        project: project,
        engines: %{"stub_vb" => {StubEngineAdapter, config}}
      )
    )

    server = Session.server(session_id)

    # 声库选择是侧表写（不进 History）
    assert {:ok, meta} = Server.update_track_voicebank(server, track_id, "stub_vb")
    assert meta.voicebank_id == "stub_vb"

    payload = %{
      phonemes: [
        %{lang: "zh", symbol: "l", start_frame: 40, end_frame: 50, note_index: 0},
        %{lang: "zh", symbol: "iang", start_frame: 50, end_frame: 92, note_index: 0}
      ],
      lead_in_sec: 0.5
    }

    assert {:ok, _track, patch} =
             Server.adopt_intervention(server, track_id,
               channel: PhonemeTiming,
               seq_id: note1,
               payload: payload
             )

    # 对拍：挂载 digest == stamp_base(channel 投影, engine_key) 的 digest
    view = Server.get_view(server)
    {:ok, base} = PhonemeTiming.projection(view.project.workspace, patch)

    {:ok, want} =
      base
      |> Channel.stamp_base(StubEngineAdapter.engine_key(config))
      |> Tamale.Digest.digest()

    assert patch.patch.base_digest == want

    # 未知声库：adopt 响亮报错
    assert {:ok, _} = Server.update_track_voicebank(server, track_id, "ghost_vb")

    assert {:error, {:unknown_voicebank, "ghost_vb"}} =
             Server.adopt_intervention(server, track_id,
               channel: PhonemeTiming,
               seq_id: note1,
               payload: payload
             )
  end

  test "Configurator 从 EngineAdapter 派生 global_rules（无 engine 为 nil 不门控）" do
    rules = %{gender: {:range, -1.0, 1.0}, phoneme_mode: {:enum, [:auto, :manual]}}

    conf = Configurator.new(engine: {StubEngineAdapter, stub_config(%{globals: rules})})
    assert conf.global_rules == rules

    assert Configurator.new().global_rules == nil
  end

  test "globals 门控：合法值过 check；违例以 :global 条目与 patch 冲突同批聚合" do
    # 合法值路径会走到 render，需会话基础设施（同 e2e 测试）
    assert {:ok, _pid} = Oi.Runtime.Session.ensure_started("engine-adapter-track_globals")

    on_exit(fn ->
      _ = Oi.Runtime.Session.stop("engine-adapter-track_globals")
    end)

    track_id = "track_globals"
    rules = %{gender: {:range, -1.0, 1.0}}
    config = stub_config(%{globals: rules})
    {dispatch, _mounted} = stamped_dispatch(track_id, config)

    # prepare_dispatch 按轨供给了 Adapter 派生的校验规则
    assert %{track_global_rules: %{^track_id => ^rules}} = dispatch

    # 合法值：check 通过直跑 render
    ok_dispatch = Map.put(dispatch, :track_globals, %{track_id => %{gender: 0.5}})
    assert {:ok, _board} = Runner.run(ok_dispatch, Blackboard.new())

    # 违例（越界 + 未知键）与 patch 冲突同批聚合，globals 条目在前
    upgraded = StubEngineAdapter.channels(stub_config(%{engine_version: "9.9.9"}))

    bad_dispatch =
      dispatch
      |> put_in([:track_channels, track_id], upgraded)
      |> Map.put(:track_globals, %{track_id => %{gender: 5.0, mode: :x}})

    assert {:error, {:check_failed, entries}} = Runner.run(bad_dispatch, Blackboard.new())

    # globals 条目在前（kind 分组断言，不依赖 map 迭代序）
    assert {globals_entries, [conflict]} = Enum.split_while(entries, &(&1.kind == :global))
    assert length(globals_entries) == 2

    assert %{track_id: ^track_id, key: :gender, reason: {:out_of_range, {-1.0, 1.0}}} =
             Enum.find(globals_entries, &(&1.key == :gender))

    assert %{track_id: ^track_id, key: :mode, reason: :unknown_global} =
             Enum.find(globals_entries, &(&1.key == :mode))

    assert %{kind: :conflict, channel: :phoneme_timing, unit_id: {^track_id, 0}} = conflict
  end

  test "globals 门控：无规则声明不门控；声明空规则则任何值都 :unknown_global" do
    # 无 Adapter / 无 engine：有值无规则（conf.global_rules 为 nil）→ 不门控
    noop = %{session_id: "globals-noop", units: [], track_globals: %{"t" => %{gender: 0.5}}}
    assert {:ok, _board} = Runner.run(noop, Blackboard.new())

    # 声明空规则（%{}）→ 声明制：不声明即不接受
    gated = %{
      session_id: "globals-empty-rules",
      units: [],
      track_globals: %{"t" => %{gender: 0.5}},
      track_global_rules: %{"t" => %{}}
    }

    assert {:error, {:check_failed, [entry]}} = Runner.run(gated, Blackboard.new())
    assert %{kind: :global, track_id: "t", key: :gender, reason: :unknown_global} = entry
  end

  test "prepare_dispatch 把 TrackMeta.globals 挂进 dispatch.track_globals（空表不出条目）" do
    track_id = "track_globals_meta"
    {:ok, project, _note1} = project_with_notes("project_globals_meta", track_id)
    project = put_voicebank(project, track_id, "stub_vb")
    {:ok, meta} = Project.track_meta(project, track_id)
    {:ok, meta} = TrackMeta.update(meta, globals: %{gender: 0.5})
    {:ok, project} = Project.put_track_meta(project, track_id, meta)

    ctx =
      Context.new("globals-meta", project,
        engines: %{"stub_vb" => {StubEngineAdapter, stub_config()}}
      )
      |> then(fn ctx -> %{ctx | graphs: %{track_id => synth_graph()}} end)

    {_ctx, dispatch} = Context.prepare_dispatch(ctx)

    assert dispatch.track_globals == %{track_id => %{gender: 0.5}}
    assert dispatch.track_global_rules == %{track_id => %{}}
  end

  test "Server：update_track_globals 合并/删除 + adopt 过 adoptables 门控" do
    session_id = "engine-adapter-gated"
    track_id = "track_srv_gated"

    {:ok, project, note1} = project_with_notes("project_srv_gated", track_id)

    start_supervised!(
      Server.child_spec(
        session_id: session_id,
        name: Session.server(session_id),
        project: project,
        engines: %{
          "stub_vb" => {StubEngineAdapter, stub_config()},
          "stub_vb_gated" => {StubEngineAdapter, stub_config(%{adoptables: []})}
        }
      )
    )

    server = Session.server(session_id)

    # globals：合并写入 + nil 删除（侧表写，不进 History）
    assert {:ok, meta} =
             Server.update_track_globals(server, track_id, gender: 0.5, phoneme_mode: :auto)

    assert meta.globals == %{gender: 0.5, phoneme_mode: :auto}

    assert {:ok, meta} = Server.update_track_globals(server, track_id, gender: nil, depth: 1.0)
    assert meta.globals == %{depth: 1.0, phoneme_mode: :auto}

    payload = %{
      phonemes: [
        %{lang: "zh", symbol: "l", start_frame: 40, end_frame: 50, note_index: 0},
        %{lang: "zh", symbol: "iang", start_frame: 50, end_frame: 92, note_index: 0}
      ],
      lead_in_sec: 0.5
    }

    # adoptables 命中的声库：adopt 正常
    assert {:ok, _} = Server.update_track_voicebank(server, track_id, "stub_vb")

    assert {:ok, _track, _patch} =
             Server.adopt_intervention(server, track_id,
               channel: PhonemeTiming,
               seq_id: note1,
               payload: payload
             )

    # adoptables 收缩为空：同一 channel 响亮拒绝（kernel 门控，Adapter 声明制）
    assert {:ok, _} = Server.update_track_voicebank(server, track_id, "stub_vb_gated")

    assert {:error, {:not_adoptable, :phoneme_timing}} =
             Server.adopt_intervention(server, track_id,
               channel: PhonemeTiming,
               seq_id: note1,
               payload: payload
             )
  end

  test "声库描述符 config：engine_key / channels / timing 从 Voicebank 派生，闭环直跑 render" do
    {:ok, vb} =
      Voicebank.new(
        id: "stub_vb",
        engine: :stub,
        engine_version: "0.0.1",
        capabilities: %{supported_channels: [:phoneme_timing]},
        timing: %{frame_rate: 50, hop: 256}
      )

    config = %{voicebank: vb}

    # 派生约定：版本戳 / channel 列表 / 帧网格全部来自描述符
    assert StubEngineAdapter.engine_key(config) == "stub_vb@0.0.1"
    assert StubEngineAdapter.timing_spec(config) == {:ok, %{frame_rate: 50, hop: 256}}

    assert %{phoneme_timing: %{projection: p, target: {:port, :synth, :phoneme_timing}}} =
             StubEngineAdapter.channels(config)

    assert is_function(p, 2)

    # 全闭环（render 需会话基础设施）：盖戳对拍走 Voicebank.engine_key
    assert {:ok, _pid} = Oi.Runtime.Session.ensure_started("engine-adapter-track_vb_cfg")

    on_exit(fn ->
      _ = Oi.Runtime.Session.stop("engine-adapter-track_vb_cfg")
    end)

    {dispatch, _mounted} = stamped_dispatch("track_vb_cfg", config)
    assert {:ok, _board} = Runner.run(dispatch, Blackboard.new())
  end

  test "曲线 channel：adopt（盖戳）→ check 对拍 → render 收到光栅化 payload" do
    session_id = "engine-adapter-curve-e2e"
    assert {:ok, _pid} = Oi.Runtime.Session.ensure_started(session_id)

    on_exit(fn ->
      _ = Oi.Runtime.Session.stop(session_id)
    end)

    track_id = "track_curve"
    unit_id = {track_id, 0}

    # 声库描述符供给曲线能力 + 帧网格（hop 25 / frame_rate 100 → 帧周期 0.25s）
    {:ok, vb} =
      Voicebank.new(
        id: "stub_vb",
        engine: :stub,
        engine_version: "0.0.1",
        capabilities: %{supported_channels: [:curve]},
        timing: %{frame_rate: 100, hop: 25}
      )

    config = %{voicebank: vb}

    {:ok, project, note1} = project_with_notes("project_curve", track_id)
    project = put_voicebank(project, track_id, "stub_vb")

    # 锚 note1（span 0..240 = 0.25s @120bpm）：两控制点 60.0 → 61.0
    {:ok, payload} =
      Curve.build_payload(:pitch, Coconut.Curve.Adapter.CatmullRom, [
        %{tick: 0, value: 60.0, handle_left: nil, handle_right: nil},
        %{tick: 240, value: 61.0, handle_left: nil, handle_right: nil}
      ])

    {:ok, patch} =
      AdoptRequest.build_patch(project.workspace, Curve, %{
        track_id: track_id,
        anchor: {:ordinal, [note1]},
        payload: payload,
        engine: StubEngineAdapter.engine_key(config)
      })

    {:ok, project, _mounted} = attach(project, patch)

    ctx =
      Context.new(session_id, project, engines: %{"stub_vb" => {StubEngineAdapter, config}})
      |> then(fn ctx -> %{ctx | graphs: %{track_id => curve_graph()}} end)

    {_ctx, dispatch} = Context.prepare_dispatch(ctx)

    assert %{track_channels: %{^track_id => %{curve: _}}} = dispatch
    assert {:ok, board} = Runner.run(dispatch, Blackboard.new())

    unit_outputs = Blackboard.fetch_via_segment(board, unit_id)

    # 光栅化 payload 落到 {:port, :synth, :pitch}（按 payload param 扇出）
    assert %{param: :pitch, start_tick: 0, end_tick: 240, stride: 25, samples: samples} =
             unit_outputs[{unit_id, "synth|pitch"}]

    assert [v0, v1] = for(<<v::float-32-native <- samples>>, do: v)
    assert_in_delta v0, 60.0, 0.01
    assert_in_delta v1, 61.0, 0.01

    assert %{received: _} = unit_outputs[{unit_id, "synth|audio"}]
  end

  # ---- 夹具（风格同 OrchidFlowTest） ----

  # 挂载 + dispatch 组合夹具：两音符工程 + 声库选择 + 盖戳 patch + engines 注册，
  # 返回 {dispatch, mounted}（无需 Oi 会话基础设施——check 失败走不到 render）
  defp stamped_dispatch(track_id, config) do
    session_id = "engine-adapter-#{track_id}"
    {:ok, project, note1} = project_with_notes("project_#{track_id}", track_id)
    project = put_voicebank(project, track_id, "stub_vb")

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
        engine: StubEngineAdapter.engine_key(config)
      })

    {:ok, project, mounted} = attach(project, patch)

    ctx =
      Context.new(session_id, project, engines: %{"stub_vb" => {StubEngineAdapter, config}})
      |> then(fn ctx -> %{ctx | graphs: %{track_id => synth_graph()}} end)

    {_ctx, dispatch} = Context.prepare_dispatch(ctx)
    {dispatch, mounted}
  end

  defp synth_graph do
    Graph.new()
    |> Graph.add_node(%Node{
      id: :synth,
      container: SynthStep,
      inputs: [:phoneme_timing],
      outputs: [:audio],
      options: []
    })
  end

  defp curve_graph do
    Graph.new()
    |> Graph.add_node(%Node{
      id: :synth,
      container: CurveSynthStep,
      inputs: [:pitch],
      outputs: [:audio],
      options: []
    })
  end

  defp put_voicebank(%Project{} = project, track_id, voicebank_id) do
    {:ok, meta} = Project.track_meta(project, track_id)
    {:ok, meta} = TrackMeta.update(meta, voicebank_id: voicebank_id)
    {:ok, project} = Project.put_track_meta(project, track_id, meta)
    project
  end

  # 经 History 挂载 patch，返回挂载后（id 已铸造）的 patch
  defp attach(%Project{} = project, patch) do
    hist = History.new(project.workspace)
    {:ok, hist} = History.run(hist, Command.attach_patches([patch]))
    project = %{project | workspace: History.current(hist).workspace}
    {:ok, track} = Project.fetch_track(project, patch.track_id)
    [mounted] = track.patches
    {:ok, project, mounted}
  end

  # 工程夹具：120bpm step tempo + 一轨两音符（0..240 / 240..720 无间隙 →
  # 单窗口 start 0）；结构写全经 coconut History/Operations
  defp project_with_notes(project_id, track_id) do
    {:ok, project} = Project.new(id: project_id, metadata: %{name: "Adapter"})
    {:ok, project, _track} = Project.add_track(project, id: track_id)

    note1 = ID.generate_id("Note_")
    note2 = ID.generate_id("Note_")

    inserts = [
      {"global:tempo", ID.generate_id("Tempo_"), :head, {0, 480}, %{bpm: 120}},
      {track_id, note1, :head, {0, 240}, %{pitch: twelve_et(60), lyric: "la"}},
      {track_id, note2, note1, {240, 720}, %{pitch: twelve_et(60), lyric: "la"}}
    ]

    {:ok, project} = apply_inserts(project, inserts)
    {:ok, project, note1}
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
