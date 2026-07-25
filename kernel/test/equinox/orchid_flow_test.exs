defmodule Equinox.Kernel.OrchidFlowTest do
  use ExUnit.Case, async: false

  alias Equinox.Kernel.{
    Blackboard,
    Compiler,
    Graph,
    Graph.Edge,
    Graph.Node,
    Runner
  }

  alias Equinox.Session.Context
  alias EquinoxDomain.Command.RenderRequest
  alias EquinoxDomain.Port.Declarations.PhonemeTiming
  alias EquinoxDomain.Score.{Project, Track}
  alias Zongzi.Intervention
  alias Zongzi.Score.Key.TwelveET
  alias Zongzi.Score.Tempo
  alias Zongzi.Util.ID

  defmodule MockSymbiontWorker do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def init(opts) do
      {:ok, %{prefix: Keyword.get(opts, :prefix, "mock")}}
    end

    def handle_call({:decorate, text}, _from, state) do
      {:reply, state.prefix <> ":" <> text, state}
    end
  end

  defmodule SourceStep do
    use Oi.Step, name: :source

    manifest(inputs: [:note], outputs: [note: :map])

    routine note, _opts do
      ok(%{lyric: note.lyric, key: note.key})
    end
  end

  defmodule DecorateStep do
    use Oi.Step, name: :decorate, symbiont?: true

    manifest(inputs: [:note], outputs: [audio: :map], models: [:mock_service])

    routine source, models, _opts do
      decorated = OrchidSymbiont.call(models.mock_service, {:decorate, source.lyric})
      ok(%{audio: decorated, key: source.key})
    end
  end

  defmodule TimingSinkStep do
    use Oi.Step, name: :timing_sink

    manifest(inputs: [:timing], outputs: [audio: :map])

    routine timing, _opts do
      ok(timing)
    end
  end

  defmodule StratumPlugin do
    @behaviour Equinox.Kernel.Plugin

    @impl true
    def apply_plugin({recipe, opts}, %{meta_store: meta_conf, blob_store: blob_conf}) do
      orchid_opts =
        Keyword.update(opts, :baggage, %{meta_store: nil, blob_store: nil}, fn baggage ->
          Map.merge(%{meta_store: nil, blob_store: nil}, baggage)
        end)

      OrchidStratum.apply_cache(recipe, meta_conf, blob_conf, orchid_opts)
    end
  end

  test "compile_track/3 reuses cached compiled graphs" do
    graph = build_flow_graph()

    assert {:ok, {^graph, %Oi.Compiled{} = compiled}, cache} =
             Compiler.compile_track("track_cached", graph)

    assert {:ok, {^graph, ^compiled}, ^cache} =
             Compiler.compile_track("track_cached", graph, cache)

    # graph 结构变化 → 缓存失效，重新编译并写回
    other_graph = Graph.new()

    assert {:ok, {^other_graph, %Oi.Compiled{} = other_compiled}, new_cache} =
             Compiler.compile_track("track_cached", other_graph, cache)

    assert new_cache["track_cached"] == {other_graph, other_compiled}
  end

  test "graph compiles into Oi.Compiled and dispatches into blackboard with symbiont-backed step" do
    session_id = "orchid-flow-session"
    assert {:ok, _pid} = Oi.Runtime.Session.ensure_started(session_id)

    on_exit(fn ->
      _ = Oi.Runtime.Session.stop(session_id)
    end)

    OrchidSymbiont.register(session_id, :mock_service, {MockSymbiontWorker, [prefix: "rendered"]})

    graph = build_flow_graph()
    track_id = "track_flow"

    # domain 夹具：两个相连音符（0..240 / 240..720，无休止间隙）→ 单窗口 start 0
    {:ok, track} = Track.new(id: track_id, name: "Flow")

    {:ok, track, _note1} =
      Track.insert_note(track, %{
        start_tick: 0,
        duration_tick: 240,
        key: twelve_et(60),
        lyric: "la"
      })

    {:ok, track, _note2} =
      Track.insert_note(track, %{
        start_tick: 240,
        duration_tick: 480,
        key: twelve_et(60),
        lyric: "la"
      })

    {:ok, project} =
      Project.new(
        id: "project_flow",
        name: "Flow",
        tempo_map: [step_tempo_event(120)]
      )

    {:ok, project} = Project.add_track(project, track)

    assert {:ok, {^graph, %Oi.Compiled{} = compiled}, _cache} =
             Compiler.compile_track(track_id, graph)

    assert [bundle] = compiled.bundles
    assert bundle.requires == ["source|note"]
    assert bundle.exports == ["decorate|audio"]

    ctx =
      session_id
      |> Context.new(project)
      |> then(fn ctx -> %{ctx | graphs: %{track_id => graph}} end)

    {context, dispatch} = Context.prepare_dispatch(ctx)

    unit_id = {track_id, 0}

    assert %{
             session_id: ^session_id,
             units: [{^unit_id, _, %RenderRequest{} = request, %Oi.Compiled{}}]
           } = dispatch

    assert request.time_range == {0, 720}
    assert length(request.notes) == 2
    assert request.interventions == []

    # 喂 source 的悬空输入（模拟上游产物已在黑板上）
    note_input_key = {unit_id, "source|note"}
    audio_output_key = {unit_id, "decorate|audio"}

    blackboard =
      Blackboard.new()
      |> Blackboard.put(%{note_input_key => %{lyric: "la", key: 60}})

    storage = Oi.Runtime.Session.storage(session_id)
    assert %{meta_store: {_, meta_ref}, blob_store: {_, blob_ref}} = storage

    assert {:ok, executed_blackboard} =
             Runner.run(dispatch, blackboard, plugins: [{StratumPlugin, storage}])

    unit_outputs = Blackboard.fetch_via_segment(executed_blackboard, unit_id)

    assert context.compile_cache[track_id]
    assert %{^audio_output_key => {:ref, {_, ^blob_ref}, _}} = unit_outputs
    assert length(:ets.tab2list(meta_ref)) == 2

    assert Enum.sort(:ets.tab2list(blob_ref)) ==
             Enum.sort([
               {elem(unit_outputs[note_input_key], 2), %{key: 60, lyric: "la"}},
               {elem(unit_outputs[audio_output_key], 2), %{audio: "rendered:la", key: 60}}
             ])
  end

  test "channel spec resolves interventions end-to-end (dangling memory + producer override)" do
    session_id = "orchid-flow-timing-session"
    assert {:ok, _pid} = Oi.Runtime.Session.ensure_started(session_id)

    on_exit(fn ->
      _ = Oi.Runtime.Session.stop(session_id)
    end)

    OrchidSymbiont.register(session_id, :mock_service, {MockSymbiontWorker, [prefix: "intv"]})

    track_id = "track_timing"
    unit_id = {track_id, 0}
    {dispatch, mounted, base} = build_timing_dispatch(session_id, track_id)

    assert %{units: [{^unit_id, _, %RenderRequest{interventions: [^mounted]}, %Oi.Compiled{}}]} =
             dispatch

    channels = %{
      PhonemeTiming.channel() => %{
        projection: fn _request -> {:ok, base} end,
        # 函数形 target：同时覆盖 dangling（sink 收 resolved 投影）与
        # producer override（source|note 固定 note map）两条装配路径
        target: fn artifact ->
          [
            {{:port, :timing_sink, :timing}, artifact},
            {{:port, :source, :note}, %{lyric: "forced", key: 61}}
          ]
        end
      }
    }

    assert {:ok, executed_blackboard} =
             Runner.run(dispatch, Blackboard.new(), channels: channels)

    unit_outputs = Blackboard.fetch_via_segment(executed_blackboard, unit_id)

    # resolve 产物：delta 应用到 base（onset +10ms / duration +20ms）后合回全量投影
    resolved = %{"ph_a" => [0.01, 0.14], "ph_b" => [0.12, 0.24]}

    note_input_key = {unit_id, "source|note"}
    audio_output_key = {unit_id, "decorate|audio"}
    timing_input_key = {unit_id, "timing_sink|timing"}
    timing_output_key = {unit_id, "timing_sink|audio"}

    assert unit_outputs[timing_input_key] == resolved
    assert unit_outputs[timing_output_key] == resolved
    assert unit_outputs[note_input_key] == %{lyric: "forced", key: 61}
    assert unit_outputs[audio_output_key] == %{audio: "intv:forced", key: 61}
  end

  test "check aggregates conflicts and skips execution when projection drifted" do
    session_id = "orchid-flow-conflict-session"
    track_id = "track_conflict"
    unit_id = {track_id, 0}
    {dispatch, mounted, _base} = build_timing_dispatch(session_id, track_id)

    # mount 时 snapshot 取自 base；check 投影漂移 → snapshot_mismatch 冲突
    drifted = %{"ph_a" => [0.0, 0.15], "ph_b" => [0.15, 0.24]}

    channels = %{
      PhonemeTiming.channel() => %{
        projection: fn _request -> {:ok, drifted} end,
        target: {:port, :timing_sink, :timing}
      }
    }

    # Runner 整体 error：check 先于任何执行，黑板不被污染
    assert {:error, {:check_failed, [entry]}} =
             Runner.run(dispatch, Blackboard.new(), channels: channels)

    assert entry.unit_id == unit_id
    assert entry.channel == PhonemeTiming.channel()
    assert entry.kind == :conflict
    assert entry.intervention_id == mounted.id
    assert {:snapshot_mismatch, _old, _new} = entry.reason
  end

  test "check reports unknown_channel when interventions lack a channel spec" do
    session_id = "orchid-flow-unknown-session"
    track_id = "track_unknown"
    unit_id = {track_id, 0}
    {dispatch, _mounted, _base} = build_timing_dispatch(session_id, track_id)

    assert {:error, {:check_failed, [entry]}} = Runner.run(dispatch, Blackboard.new())

    assert entry.unit_id == unit_id
    assert entry.channel == PhonemeTiming.channel()
    assert entry.kind == :unknown_channel
  end

  defp build_flow_graph do
    Graph.new()
    |> Graph.add_node(%Node{
      id: :source,
      container: SourceStep,
      inputs: [:note],
      outputs: [:note],
      options: []
    })
    |> Graph.add_node(%Node{
      id: :decorate,
      container: DecorateStep,
      inputs: [:note],
      outputs: [:audio],
      options: []
    })
    |> Graph.add_edge(Edge.new(:source, :note, :decorate, :note))
  end

  defp build_timing_graph do
    build_flow_graph()
    |> Graph.add_node(%Node{
      id: :timing_sink,
      container: TimingSinkStep,
      inputs: [:timing],
      outputs: [:audio],
      options: []
    })
  end

  # phoneme_timing 端到端夹具：两音符（0..240 / 240..720 无间隙 → 单窗口
  # start 0），首音符上挂载一条 phoneme_timing 干预；工程带 120bpm step tempo
  defp build_timing_dispatch(session_id, track_id) do
    graph = build_timing_graph()

    {:ok, track} = Track.new(id: track_id, name: "Timing")

    {:ok, track, note1} =
      Track.insert_note(track, %{
        start_tick: 0,
        duration_tick: 240,
        key: twelve_et(60),
        lyric: "la"
      })

    {:ok, track, _note2} =
      Track.insert_note(track, %{
        start_tick: 240,
        duration_tick: 480,
        key: twelve_et(60),
        lyric: "la"
      })

    base = %{"ph_a" => [0.0, 0.12], "ph_b" => [0.12, 0.24]}

    {:ok, intervention} =
      Intervention.new(
        id: ID.generate_id("iv_"),
        channel: PhonemeTiming.channel(),
        declaration: PhonemeTiming
      )

    payload = %{
      range: [0, 240],
      deltas: [%{identity: "ph_a", onset_delta_ms: 10, duration_delta_ms: 20}]
    }

    {:ok, track, mounted} =
      Track.mount_intervention(track, intervention, payload, note1.seq_id, base)

    {:ok, project} =
      Project.new(
        id: "project_#{track_id}",
        name: "Timing",
        tempo_map: [step_tempo_event(120)]
      )

    {:ok, project} = Project.add_track(project, track)

    ctx =
      session_id
      |> Context.new(project)
      |> then(fn ctx -> %{ctx | graphs: %{track_id => graph}} end)

    {_ctx, dispatch} = Context.prepare_dispatch(ctx)

    {dispatch, mounted, base}
  end

  # zongzi tempo 源事件：`{tick, %Tempo.Event{module, context}}`
  defp step_tempo_event(bpm), do: {0, %Tempo.Event{module: Tempo.Step, context: %{bpm: bpm}}}

  defp twelve_et(midi) do
    {:ok, key} = TwelveET.new(midi)
    key
  end
end
