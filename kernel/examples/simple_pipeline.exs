defmodule DemoSteps.Phonemizer do
  use Orchid.Step
  alias Orchid.Param

  def run(notes_param, _opts) do
    notes = Param.get_payload(notes_param)
    IO.puts("🔤 Phonemizing #{length(notes)} notes...")
    phonemized = Enum.map(notes, fn note -> "#{note.lyric}_phonemes" end)
    {:ok, Param.new(:linguistic, :linguistic) |> Param.set_payload(phonemized)}
  end
end

defmodule DemoSteps.AcousticModel do
  use Orchid.Step
  alias Orchid.Param

  def run([notes_param, linguistic_param], _opts) do
    notes = Param.get_payload(notes_param)
    linguistic = Param.get_payload(linguistic_param)
    IO.puts("🎵 Generating acoustic features...")
    features = Enum.zip_with(notes, linguistic, fn note, phonemes -> "Features[#{note.lyric}, #{phonemes}]" end)
    {:ok, Param.new(:features, :features) |> Param.set_payload(features)}
  end
end

defmodule DemoSteps.Vocoder do
  use Orchid.Step
  alias Orchid.Param

  def run(features_param, _opts) do
    features = Param.get_payload(features_param)
    IO.puts("🔊 Rendering audio with vocoder...")
    audio = Enum.map(features, fn feature -> "Audio[#{feature}]" end)
    {:ok, Param.new(:audio, :audio) |> Param.set_payload(audio)}
  end
end

defmodule Examples.SimplePipeline do
  @moduledoc false

  alias Equinox.Domain.Note
  alias Equinox.Kernel.{Blackboard, Configurator, Graph, GraphBuilder, RecipeBundle, StepRegistry}

  @demo_registry_steps [
    {:demo_simple_phonemizer,
     %{module: DemoSteps.Phonemizer, inputs: [:notes], outputs: [:linguistic], options: []}},
    {:demo_simple_acoustic,
     %{module: DemoSteps.AcousticModel, inputs: [:notes, :linguistic], outputs: [:features], options: []}},
    {:demo_simple_vocoder,
     %{module: DemoSteps.Vocoder, inputs: [:features], outputs: [:audio], options: []}}
  ]

  def run do
    Application.ensure_all_started(:equinox)

    notes = sample_notes()

    print_banner()
    run_direct_orchid(notes)
    divider()
    run_equinox_kernel(notes)
    divider()
    run_step_registry_demo()
    finish_banner()
  end

  defp print_banner do
    IO.puts("=" <> String.duplicate("=", 50))
    IO.puts("🌅 Equinox + Orchid 管线演示")
    IO.puts("=" <> String.duplicate("=", 50))
    IO.puts("")
  end

  defp divider do
    IO.puts("")
    IO.puts(String.duplicate("=", 50))
    IO.puts("")
  end

  defp finish_banner do
    IO.puts("=" <> String.duplicate("=", 50))
    IO.puts("✅ 演示完成！")
  end

  defp sample_notes do
    [
      Note.new(%{lyric: "hello"}),
      Note.new(%{lyric: "world"}),
      Note.new(%{lyric: "from"}),
      Note.new(%{lyric: "equinox"})
    ]
  end

  defp run_direct_orchid(notes) do
    IO.puts("方法 1: 直接使用 Orchid")
    IO.puts(String.duplicate("-", 30))

    initial_params = [
      Orchid.Param.new(:notes, :sequence) |> Orchid.Param.set_payload(notes)
    ]

    steps = [
      {DemoSteps.Phonemizer, :notes, :linguistic},
      {DemoSteps.AcousticModel, [:notes, :linguistic], :features},
      {DemoSteps.Vocoder, :features, :audio}
    ]

    recipe = Orchid.Recipe.new(steps, name: "demo_svs_pipeline")

    case Orchid.run(recipe, initial_params) do
      {:ok, results} ->
        audio = Orchid.Param.get_payload(results[:audio])
        IO.puts("✅ 管线执行成功！")
        IO.puts("生成的音频：")
        Enum.each(audio, &IO.puts("  - #{&1}"))

      {:error, reason} ->
        IO.puts("❌ 管线执行失败: #{inspect(reason)}")
    end
  end

  defp run_equinox_kernel(notes) do
    IO.puts("方法 2: 使用 Equinox Kernel")
    IO.puts(String.duplicate("-", 30))
    IO.puts("路径: GraphBuilder -> RecipeBundle.bind_interventions -> Engine.run")

    segment_id = "demo_segment_1"
    graph = build_demo_graph()
    interventions = build_interventions(notes)

    IO.puts("📦 正在编译 Graph -> RecipeBundle...")

    {:ok, [bundle]} =
      graph
      |> GraphBuilder.compile_graph()
      |> then(fn {:ok, static_bundles} ->
        {:ok, RecipeBundle.bind_interventions(static_bundles, interventions)}
      end)

    IO.puts("✅ 编译成功！")
    IO.puts("🚀 正在运行管线...")

    blackboard = Blackboard.new()
    config = Configurator.new()

    case Equinox.Kernel.Engine.run(segment_id, bundle, blackboard, config) do
      {:ok, _segment_id, results} ->
        IO.puts("✅ Equinox 管线执行成功！")
        IO.puts("结果:")

        results
        |> Enum.map(fn {key, %Orchid.Param{payload: payload}} -> {key, payload} end)
        |> Enum.into(%{})
        |> IO.inspect(pretty: true)

      {:error, reason} ->
        IO.puts("❌ 管线执行失败: #{inspect(reason)}")
    end
  end

  defp build_demo_graph do
    Graph.new()
    |> Graph.add_node(%Graph.Node{
      id: :phonemizer,
      container: DemoSteps.Phonemizer,
      inputs: [:notes],
      outputs: [:linguistic]
    })
    |> Graph.add_node(%Graph.Node{
      id: :acoustic,
      container: DemoSteps.AcousticModel,
      inputs: [:notes, :linguistic],
      outputs: [:features]
    })
    |> Graph.add_node(%Graph.Node{
      id: :vocoder,
      container: DemoSteps.Vocoder,
      inputs: [:features],
      outputs: [:audio]
    })
    |> Graph.add_edge(Graph.Edge.new(:phonemizer, :linguistic, :acoustic, :linguistic))
    |> Graph.add_edge(Graph.Edge.new(:acoustic, :features, :vocoder, :features))
  end

  defp build_interventions(notes) do
    %{
      {:port, :phonemizer, :notes} => %{input: notes},
      {:port, :acoustic, :notes} => %{input: notes}
    }
  end

  defp run_step_registry_demo do
    IO.puts("📋 测试 StepRegistry:")
    IO.puts(String.duplicate("-", 30))

    try do
      Enum.each(@demo_registry_steps, fn {name, spec} ->
        StepRegistry.unregister(name)
        StepRegistry.register(name, spec)
      end)

      Enum.each(@demo_registry_steps, fn {name, _spec} ->
        case StepRegistry.lookup(name) do
          {:ok, spec} ->
            IO.puts("  • #{name} (Module: #{inspect(spec.module)})")

          :error ->
            IO.puts("  • #{name} lookup failed")
        end
      end)
    after
      Enum.each(@demo_registry_steps, fn {name, _spec} -> StepRegistry.unregister(name) end)
    end
  end
end

Examples.SimplePipeline.run()
