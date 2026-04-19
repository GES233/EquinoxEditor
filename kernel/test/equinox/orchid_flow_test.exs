defmodule Equinox.Kernel.OrchidFlowTest do
  use ExUnit.Case, async: false

  alias Equinox.Domain.Note
  alias Equinox.Track
  alias Equinox.Editor.Segment
  alias Equinox.Kernel.{Blackboard, Dispatcher, Graph, Graph.Edge, Graph.Node, GraphBuilder, Planner, RecipeBundle}
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
    use Orchid.Step
    alias Orchid.Param

    def run(note_param, _opts) do
      note = Param.get_payload(note_param)
      payload = %{lyric: note.lyric, key: note.key}
      {:ok, Param.new("source|note", :map) |> Param.set_payload(payload)}
    end
  end

  defmodule DecorateStep do
    @behaviour OrchidSymbiont.Step
    alias Orchid.Param

    @impl true
    def required, do: [:mock_service]

    @impl true
    def run_with_model(source_param, handlers, _opts) do
      source = Param.get_payload(source_param)
      decorated = OrchidSymbiont.call(handlers[:mock_service], {:decorate, source.lyric})

      {:ok,
       Param.new("decorate|audio", :map)
       |> Param.set_payload(%{audio: decorated, key: source.key})}
    end
  end

  test "graph compiles into orchid recipes and dispatches into blackboard with symbiont-backed step" do
    session_id = "orchid-flow-session"
    assert {:ok, _pid} = OrchidSymbiont.Runtime.start_link(scope_id: session_id)

    on_exit(fn ->
      supervisor = Process.whereis(OrchidSymbiont.Supervisor)

      if is_pid(supervisor) do
        DynamicSupervisor.which_children(OrchidSymbiont.DynamicSupervisor)
      end
    end)

    OrchidSymbiont.register(session_id, :mock_service, {MockSymbiontWorker, [prefix: "rendered"]})

    graph =
      Graph.new()
      |> Graph.add_node(%Node{id: :source, container: SourceStep, inputs: [:note], outputs: [:note], options: []})
      |> Graph.add_node(%Node{
        id: :decorate,
        container: DecorateStep,
        inputs: [:note],
        outputs: [:audio],
        options: [extra_hooks_stack: [OrchidSymbiont.Hooks.Injector]]
      })
      |> Graph.add_edge(Edge.new(:source, :note, :decorate, :note))

    segment =
      Segment.new(%{
        id: "segment_flow",
        track_id: "track_flow",
        notes: [Note.new(%{id: "note_1", start_tick: 0, duration_tick: 480, key: 60, lyric: "la"})],
        graph: graph
      })

    track = Track.new(%{id: "track_flow", segments: %{"segment_flow" => segment}})
    project = Project.new(%{id: "project_flow", tracks: %{"track_flow" => track}})

    assert {:ok, recipe_bundles} = GraphBuilder.compile_graph(graph)
    assert [%RecipeBundle{} = recipe_bundle] = recipe_bundles
    assert recipe_bundle.requires == ["source|note"]
    assert recipe_bundle.exports == ["decorate|audio"]

    {context, plan} = Context.dispatch_to_plans(Context.new(session_id, project, nil))
    assert %Planner.Plan{total_tasks: 1, stages: [%Planner.Stage{tasks: [{"segment_flow", _bundle}]}]} = plan

    note_input = hd(segment.notes)

    blackboard =
      Blackboard.new()
      |> Blackboard.put(%{{"segment_flow", "source|note"} => %{lyric: note_input.lyric, key: note_input.key}})

    assert {:ok, executed_blackboard} =
             Dispatcher.dispatch(plan, blackboard, orchid_baggage: [scope_id: session_id])

    assert %{{"segment_flow", "decorate|audio"} => %{audio: "rendered:la", key: 60}} =
             Blackboard.fetch_via_segment(executed_blackboard, "segment_flow")

    assert context.static_bundles_cache["segment_flow"]
  end
end
