defmodule Neumu.ProjectStub do
  @moduledoc """
  测试用的最小 `Neume.MultiTrack` 值。

  构造真实的 `Coconut.Session`/History（ProjectServer 需要从中读取
  cursor pin）；pickle/voicebank registry 与 mix pipeline 使用类型合法但
  为空的运行时值，渲染路径由注入的 renderer 接管，不触碰声库与推理。
  """

  alias Coconut.Edit.{History, Workspace}

  @doc "构造一个带唯一 id、空工程历史的 MultiTrack 值。"
  @spec multi_track(term()) :: Neume.MultiTrack.t()
  def multi_track(tag \\ "project") do
    {:ok, workspace} = Workspace.new(%{id: "ws-#{tag}", tracks: %{}})
    {:ok, mix_pipeline} = Neume.MixPipeline.compile(output_dir: "tmp/neumu-test")

    %Neume.MultiTrack{
      session: %Coconut.Session{history: History.new(workspace)},
      pickle_registry: Coconut.Pickle.Track.default_registry(),
      voicebank_registry: %Neume.Voicebank.Registry{entries: %{}, diagnostics: []},
      tracks: %{},
      mix_pipeline: mix_pipeline,
      output_dir: "tmp/neumu-test",
      open_opts: []
    }
  end

  @doc "一个最小合法 MixArtifact。"
  @spec mix_artifact() :: Neume.MixArtifact.t()
  def mix_artifact do
    %Neume.MixArtifact{
      path: "tmp/neumu-test/mix.wav",
      sample_rate: 44_100,
      sample_count: 0,
      duration_sec: 0.0,
      track_ids: []
    }
  end

  # --- facade 测试：带真实声库条目的工程 ---

  @doc "扫描 fixture 声库目录，返回注册表与唯一 stock entry。"
  @spec stock_registry(Path.t()) :: {Neume.Voicebank.Registry.t(), Neume.Voicebank.Entry.t()}
  def stock_registry(tmp_dir) do
    root = Neumu.VoicebankFixture.diffsinger(tmp_dir)
    {:ok, registry} = Neume.Voicebank.Registry.discover(root)
    [stock] = Enum.filter(Neume.Voicebank.Registry.list(registry), &(&1.mode == :stock))
    {registry, stock}
  end

  @doc """
  构造一个 Modified entry（假 FP manifest 文件），用于声库重绑定测试。
  调用方负责把它放进注册表：`%{registry | entries: Map.put(registry.entries, entry.id, entry)}`。
  """
  @spec modified_entry(Neume.Voicebank.Entry.t(), Path.t()) :: Neume.Voicebank.Entry.t()
  def modified_entry(%Neume.Voicebank.Entry{mode: :stock} = stock, tmp_dir) do
    dir = Path.join(tmp_dir, "modified")
    File.mkdir_p!(dir)
    manifest_path = Path.join(dir, "fp_manifest.json")
    File.write!(manifest_path, "{}")

    fp = %{
      manifest_path: manifest_path,
      manifest_digest: String.duplicate("a", 64),
      models: %{},
      noise: %{},
      noise_version: 1
    }

    Neume.Voicebank.Entry.modified(stock.manifest, fp)
  end

  @doc "create/load_project 的打开选项：注入注册表、不触碰推理的 client 与独立输出目录。"
  @spec open_opts(Neume.Voicebank.Registry.t(), Path.t()) :: keyword()
  def open_opts(registry, tmp_dir) do
    [
      voicebank_registry: registry,
      diffsinger_client: Neumu.ProjectStub.UnusedClient,
      output_dir: Path.join(tmp_dir, "renders")
    ]
  end
end

defmodule Neumu.ProjectStub.UnusedClient do
  @moduledoc false
  # 声库解析与管线编译期不调用 client；只有真实 probe/render 才会触发。
  @behaviour Neume.Engine.DiffSingerWorker

  @impl true
  def call(_payload, _config), do: {:error, :not_used}
end
