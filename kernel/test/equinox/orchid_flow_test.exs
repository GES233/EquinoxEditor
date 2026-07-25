defmodule Equinox.Kernel.OrchidFlowTest do
  use ExUnit.Case, async: false

  alias Equinox.Domain.Note
  alias Equinox.Track
  alias Equinox.Domain.Segment

  alias Equinox.Kernel.{
    Blackboard,
    Compiler,
    Graph,
    Graph.Edge,
    Graph.Node,
    Runner
  }

  alias Equinox.Project
  alias Equinox.Session.Context

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

  test "compile_segments/2 reuses cached compiled segments" do
    graph = build_flow_graph()
    segment = build_flow_segment("segment_cached", graph, "note_cached")

    assert {:ok,
            {"segment_cached", cached_graph, cached_interventions, %Oi.Compiled{} = compiled}} =
             Compiler.compile_segment(segment)

    cache = %{"segment_cached" => {cached_graph, cached_interventions, compiled}}

    assert {:ok, [{"segment_cached", ^cached_graph, ^cached_interventions, ^compiled}]} =
             Compiler.compile_segments([segment], cache)
  end

  test "graph compiles into Oi.Compiled and dispatches into blackboard with symbiont-backed step" do
    session_id = "orchid-flow-session"
    assert {:ok, _pid} = Oi.Runtime.Session.ensure_started(session_id)

    on_exit(fn ->
      _ = Oi.Runtime.Session.stop(session_id)
    end)

    OrchidSymbiont.register(session_id, :mock_service, {MockSymbiontWorker, [prefix: "rendered"]})

    graph = build_flow_graph()
    segment = build_flow_segment("segment_flow", graph, "note_1")

    track = Track.new(%{id: "track_flow", segments: %{"segment_flow" => segment}})
    project = Project.new(%{id: "project_flow", tracks: %{"track_flow" => track}})

    assert {:ok, {"segment_flow", _graph, _interventions, %Oi.Compiled{} = compiled}} =
             Compiler.compile_segment(segment)

    assert [bundle] = compiled.bundles
    assert bundle.requires == ["source|note"]
    assert bundle.exports == ["decorate|audio"]

    {context, dispatch} =
      session_id
      |> Context.new(project)
      |> Context.prepare_dispatch()

    assert %{session_id: ^session_id, units: [{"segment_flow", _, _, %Oi.Compiled{}}]} = dispatch

    note_input = hd(segment.notes)

    blackboard =
      Blackboard.new()
      |> Blackboard.put(%{
        {"segment_flow", "source|note"} => %{lyric: note_input.lyric, key: note_input.key}
      })

    storage = Oi.Runtime.Session.storage(session_id)
    assert %{meta_store: {_, meta_ref}, blob_store: {_, blob_ref}} = storage

    assert {:ok, executed_blackboard} =
             Runner.run(dispatch, blackboard, plugins: [{StratumPlugin, storage}])

    segment_outputs = Blackboard.fetch_via_segment(executed_blackboard, "segment_flow")

    assert context.compile_cache["segment_flow"]
    assert %{{"segment_flow", "decorate|audio"} => {:ref, {_, ^blob_ref}, _}} = segment_outputs
    assert length(:ets.tab2list(meta_ref)) == 2

    assert Enum.sort(:ets.tab2list(blob_ref)) ==
             Enum.sort([
               {elem(segment_outputs[{"segment_flow", "source|note"}], 2),
                %{key: 60, lyric: "la"}},
               {elem(segment_outputs[{"segment_flow", "decorate|audio"}], 2),
                %{audio: "rendered:la", key: 60}}
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
    segment = build_flow_segment("segment_intv", graph, "note_intv")

    assert {:ok, {"segment_intv", unit_graph, _interventions, %Oi.Compiled{} = compiled}} =
             Compiler.compile_segment(segment)

    # {:port, :source, :note} 既是 source 的悬空输入端口，又是通往 decorate 的
    # producer 输出端口：同一干预同时覆盖两条装配路径。
    interventions = %{{:port, :source, :note} => %{input: %{lyric: "forced", key: 61}}}

    dispatch = %{
      session_id: session_id,
      units: [{"segment_intv", unit_graph, interventions, compiled}]
    }

    assert {:ok, executed_blackboard} = Runner.run(dispatch, Blackboard.new())

    segment_outputs = Blackboard.fetch_via_segment(executed_blackboard, "segment_intv")

    # 无 Stratum 插件时输出为裸 payload
    assert %{{"segment_intv", "source|note"} => %{lyric: "forced", key: 61}} =
             segment_outputs

    assert %{{"segment_intv", "decorate|audio"} => %{audio: "intv:forced", key: 61}} =
             segment_outputs
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

  defp build_flow_segment(segment_id, graph, note_id) do
    Segment.new(%{
      id: segment_id,
      track_id: "track_flow",
      notes: [
        Note.new(%{id: note_id, start_tick: 0, duration_tick: 480, key: 60, lyric: "la"})
      ],
      graph: graph
    })
  end
end
