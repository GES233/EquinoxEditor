defmodule Equinox.Domain.Note do
  defstruct [:lyric]
  def new(opts), do: struct!(__MODULE__, opts)
end

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
    features = Enum.zip_with(notes, linguistic, fn n, l -> "Features[#{n.lyric}, #{l}]" end)
    {:ok, Param.new(:features, :features) |> Param.set_payload(features)}
  end
end

defmodule DemoSteps.Vocoder do
  use Orchid.Step
  alias Orchid.Param

  def run(features_param, _opts) do
    features = Param.get_payload(features_param)
    IO.puts("🔊 Rendering audio with vocoder...")
    audio = Enum.map(features, fn f -> "Audio[#{f}]" end)
    {:ok, Param.new(:audio, :audio) |> Param.set_payload(audio)}
  end
end

# 启动应用
Application.ensure_all_started(:equinox)

IO.puts("=" <> String.duplicate("=", 50))
IO.puts("🌅 Equinox + Orchid 管线演示")
IO.puts("=" <> String.duplicate("=", 50))
IO.puts("")

notes = [
  Equinox.Domain.Note.new(lyric: "hello"),
  Equinox.Domain.Note.new(lyric: "world"),
  Equinox.Domain.Note.new(lyric: "from"),
  Equinox.Domain.Note.new(lyric: "equinox")
]

# ==============================================================================
# 方法 1: 直接使用 Orchid
# ==============================================================================
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

IO.puts("")
IO.puts(String.duplicate("=", 50))
IO.puts("")

# ==============================================================================
# 方法 2: 使用 Equinox Kernel (Graph + Track + Compiler + Engine)
# ==============================================================================
IO.puts("方法 2: 使用 Equinox Kernel")
IO.puts(String.duplicate("-", 30))

alias Equinox.Kernel.Graph

# 1. 创建 Equinox Graph
graph =
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

# 2. 将 Graph 注入 Segment (因为 Compiler 现在以 Segment 为输入)
segment_id = "test_segment_1"
segment = Equinox.Editor.Segment.new(segment_id, graph)

segment =
  Equinox.Editor.Segment.inject_graph_and_interventions(
    segment,
    graph,
    %{
      {:port, :phonemizer, :notes} => %{input: notes},
      {:port, :acoustic, :notes} => %{input: notes}
    }
  )

track_id = "test_track_1"
track = Equinox.Editor.Track.new(track_id, :synth)
{:ok, track} = Equinox.Editor.Track.add_segment(track, segment)

# 3. 编译
IO.puts("📦 正在编译 Track -> RecipeBundle...")
{:ok, [{^segment_id, [bundle]}]} = Equinox.Kernel.Compiler.compile_to_recipes([segment])
IO.puts("✅ 编译成功！")

# 4. 准备数据并运行
IO.puts("🚀 正在运行管线...")
blackboard = Equinox.Kernel.Blackboard.new()
config = Equinox.Kernel.Configurator.new()

case Equinox.Kernel.Engine.run(segment_id, bundle, blackboard, config) do
  {:ok, _id, results} ->
    IO.puts("✅ Equinox 管线执行成功！")
    IO.puts("结果: ")

    results
    |> Enum.map(fn {k, %Orchid.Param{payload: p}} -> {k, p} end)
    |> Enum.into(%{})
    |> IO.inspect(pretty: true)

  {:error, reason} ->
    IO.puts("❌ 管线执行失败: #{inspect(reason)}")
end

IO.puts("")
IO.puts("=" <> String.duplicate("=", 50))

# ==============================================================================
# 测试 StepRegistry
# ==============================================================================
IO.puts("📋 测试 StepRegistry:")
IO.puts(String.duplicate("-", 30))

Equinox.Kernel.StepRegistry.register(:phonemizer, %{
  module: DemoSteps.Phonemizer,
  inputs: [:notes],
  outputs: [:linguistic],
  options: []
})

Equinox.Kernel.StepRegistry.register(:acoustic, %{
  module: DemoSteps.AcousticModel,
  inputs: [:notes, :linguistic],
  outputs: [:features],
  options: []
})

Equinox.Kernel.StepRegistry.list_all()
|> Enum.each(fn {name, spec} ->
  IO.puts("  • #{name} (Module: #{inspect(spec.module)})")
end)

IO.puts("=" <> String.duplicate("=", 50))
IO.puts("✅ 演示完成！")
