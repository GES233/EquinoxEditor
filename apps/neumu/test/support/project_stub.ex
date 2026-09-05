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
  def open_opts(registry, tmp_dir), do: open_opts(registry, tmp_dir, UnusedClient)

  @doc """
  同 `open_opts/2`，但指定 worker client。pin 族测试用
  `Neumu.ProjectStub.PhonemesClient`（expand/encode 可probe）。
  """
  @spec open_opts(Neume.Voicebank.Registry.t(), Path.t(), module()) :: keyword()
  def open_opts(registry, tmp_dir, client) do
    [
      voicebank_registry: registry,
      diffsinger_client: client,
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

defmodule Neumu.ProjectStub.PhonemesClient do
  @moduledoc false
  # expand/check-capable 假 client：probe（G2P + 组展开）与 check（假预测）
  # 的确定性纯 Elixir 实现，移植自 apps/neume/test/support 的约定——组展开
  # 用"头词末音素当延续元音"的近似（与 mock pipeline 一致）。不实现
  # render：测试不走合成。
  @behaviour Neume.Engine.DiffSingerWorker

  @impl true
  def call(%{action: "encode", notes: notes}, _config) do
    tokens =
      Map.new(notes, fn note ->
        phonemes = Enum.map(String.graphemes(note.lyric), &[note.language, &1])
        {to_string(note.id), phonemes}
      end)

    {:ok, %{"tokens" => tokens}}
  end

  def call(%{action: "expand", words: words} = payload, _config) do
    {:ok, %{"note_phonemes" => note_phonemes(words, Map.get(payload, :groups))}}
  end

  def call(%{action: "check", words: words} = payload, _config) do
    durations =
      Enum.map(words, fn [phonemes, seconds | _rest] ->
        length(phonemes) * round(seconds * 44_100 / 512)
      end)

    frame_count = Enum.sum(durations)

    {:ok,
     %{
       "ph_dur" => durations,
       "pitch_pred_midi" => List.duplicate(60.0, frame_count),
       "total_frames" => frame_count,
       "lead_in_sec" => 0.5,
       "note_phonemes" => note_phonemes(words, Map.get(payload, :groups)),
       "phonemes" => [
         %{
           "language" => "zh",
           "symbol" => "SP",
           "type" => "rest",
           "start_frame" => 0,
           "end_frame" => 43,
           "note_index" => nil,
           "phoneme_index" => 0
         },
         %{
           "language" => "zh",
           "symbol" => "a",
           "type" => "vowel",
           "start_frame" => 43,
           "end_frame" => frame_count,
           "note_index" => 0,
           "phoneme_index" => 0
         }
       ]
     }}
  end

  def call(_payload, _config), do: {:error, :not_used}

  # 拼音韵母近似表：只用于判断替身近似是否成立（黄金向量
  # apps/neume/test/fixtures/expand_vectors.json 钉住一致性）。
  @approx_vowels ~w(a o e i u v ü ai ei ao ou an en ang eng ong er)

  # 按原 words 下标（字符串 key）归并逐词音素序列。
  defp note_phonemes(words, groups) do
    member_vowels =
      for [head | members] <- groups || [],
          member <- members,
          into: %{} do
        [phonemes | _rest] = Enum.at(words, head)
        {member, [last_vowel!(phonemes, head)]}
      end

    words
    |> Enum.with_index()
    |> Map.new(fn {word, index} ->
      phonemes =
        case Map.fetch(member_vowels, index) do
          {:ok, vowel} -> vowel
          :error -> hd(word)
        end

      {to_string(index), phonemes}
    end)
  end

  # 近似前置断言：末音素必须是已知元音，否则替身与真身必然分歧。
  defp last_vowel!(phonemes, head_index) do
    [language, phone] = List.last(phonemes)

    if phone in @approx_vowels do
      [language, phone]
    else
      raise ArgumentError,
            "fake expand 近似不成立：头词 #{head_index} 末音素 #{inspect(phone)} 不是已知元音"
    end
  end
end
