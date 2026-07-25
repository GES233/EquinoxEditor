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
  alias EquinoxDomain.Score.{Project, Track}
  alias Zongzi.Score.Key.TwelveET

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

    {:ok, project} = Project.new(id: "project_flow", name: "Flow")
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
    assert %{session_id: ^session_id, units: [{^unit_id, _, _, %Oi.Compiled{}}]} = dispatch

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

  test "interventions feed the run when blackboard misses (memory + producer override)" do
    session_id = "orchid-flow-intervention-session"
    assert {:ok, _pid} = Oi.Runtime.Session.ensure_started(session_id)

    on_exit(fn ->
      _ = Oi.Runtime.Session.stop(session_id)
    end)

    OrchidSymbiont.register(session_id, :mock_service, {MockSymbiontWorker, [prefix: "intv"]})

    graph = build_flow_graph()
    track_id = "track_intv"
    unit_id = {track_id, 0}

    assert {:ok, {unit_graph, %Oi.Compiled{} = compiled}, _cache} =
             Compiler.compile_track(track_id, graph)

    # {:port, :source, :note} 既是 source 的悬空输入端口，又是通往 decorate 的
    # producer 输出端口：同一干预同时覆盖两条装配路径。
    interventions = %{{:port, :source, :note} => %{input: %{lyric: "forced", key: 61}}}

    dispatch = %{
      session_id: session_id,
      units: [{unit_id, unit_graph, interventions, compiled}]
    }

    assert {:ok, executed_blackboard} = Runner.run(dispatch, Blackboard.new())

    unit_outputs = Blackboard.fetch_via_segment(executed_blackboard, unit_id)

    note_input_key = {unit_id, "source|note"}
    audio_output_key = {unit_id, "decorate|audio"}

    # 无 Stratum 插件时输出为裸 payload
    assert %{^note_input_key => %{lyric: "forced", key: 61}} = unit_outputs
    assert %{^audio_output_key => %{audio: "intv:forced", key: 61}} = unit_outputs
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

  defp twelve_et(midi) do
    {:ok, key} = TwelveET.new(midi)
    key
  end
end
