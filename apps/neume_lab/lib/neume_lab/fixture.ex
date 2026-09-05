defmodule NeumeLab.Fixture do
  @moduledoc """
  演示工程装配：fixture 声库 + `NeumeLab.DemoClient` + 起手音符。

  声库目录是 OpenUtau 格式占位模型（配置、八个模型占位、字典与 speaker
  embedding 齐全，过 `Neume.DiffSinger.scan/1` 严格校验），与
  `apps/neumu/test/support/voicebank_fixture.ex` 同构；umbrella 各 app 的
  test/support 不互相共享，这里保留一份实验台自有的拷贝。
  """

  alias Neume.Voicebank.Registry, as: VoicebankRegistry

  @typedoc "演示工程句柄：facade 调用所需的 identity 与落盘目录。"
  @type demo :: %{project_id: String.t(), stock_id: String.t(), dir: Path.t()}

  @doc """
  打开一个演示工程：`dir` 下写 fixture 声库（已存在则复用），建一条
  "lead" 轨与四个显式音素的音符（do/re/mi/fa，C4 起音阶）。
  """
  @spec open_demo(keyword()) :: demo()
  def open_demo(opts \\ []) do
    dir = Keyword.get(opts, :dir, default_dir())
    root = voicebank(dir)
    {:ok, registry} = VoicebankRegistry.discover(root)
    [stock] = Enum.filter(VoicebankRegistry.list(registry), &(&1.mode == :stock))

    project_id = Keyword.get(opts, :project_id, "lab-#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      Neumu.create_project(project_id,
        voicebank_registry: registry,
        diffsinger_client: NeumeLab.DemoClient,
        output_dir: Path.join(dir, "renders")
      )

    {:ok, _pin} = Neumu.add_track(project_id, "lead", stock.id, %{name: "主唱"})

    notes = [
      {"n1", {0, 480}, 60, "do", [["zh", "d"], ["zh", "o"]]},
      {"n2", {480, 960}, 62, "re", [["zh", "r"], ["zh", "e"]]},
      {"n3", {960, 1440}, 64, "mi", [["zh", "m"], ["zh", "i"]]},
      {"n4", {1440, 1920}, 65, "fa", [["zh", "f"], ["zh", "a"]]}
    ]

    for {note_id, span, pitch, lyric, phonemes} <- notes do
      {:ok, _pin} =
        Neumu.insert_note(project_id, "lead", note_id, :head, span, %{
          pitch: pitch,
          lyric: lyric,
          phonemes: phonemes
        })
    end

    %{project_id: project_id, stock_id: stock.id, dir: dir}
  end

  @doc "演示工程默认落盘目录（umbrella 根下的 `tmp/neume_lab`）。"
  @spec default_dir() :: Path.t()
  def default_dir, do: Path.expand("tmp/neume_lab")

  @doc """
  在 `parent` 下写 fixture 声库目录并返回其路径；目录已含 dsconfig 时
  跳过写入（幂等，供重复打开演示工程）。
  """
  @spec voicebank(Path.t()) :: Path.t()
  def voicebank(parent) do
    root = Path.join(parent, "voicebank")

    if File.exists?(Path.join(root, "dsconfig.yaml")) do
      root
    else
      write_voicebank(root)
    end
  end

  defp write_voicebank(root) do
    for directory <- ["dsdur", "dspitch", "dsvariance", "dsvocoder", "linguistic", "embeds"] do
      File.mkdir_p!(Path.join(root, directory))
    end

    write(root, "character.txt", "name=Lab Singer\nauthor=NeumeLab\n")
    write(root, "languages.json", ~s({"zh":1}))
    write(root, "phonemes.json", ~s({"SP":1,"zh/a":2}))
    write(root, "dsdict-zh.yaml", "entries: []\n")
    write(root, "dsdur/dsdict-zh.yaml", "entries: []\n")

    write(
      root,
      "dsconfig.yaml",
      """
      phonemes: phonemes.json
      languages: languages.json
      acoustic: acoustic.onnx
      speakers: [Normal]
      use_breathiness_embed: true
      sample_rate: 44100
      hop_size: 512
      """
    )

    write(root, "dsdur/dsconfig.yaml", stage_config("dur", "duration.onnx"))
    write(root, "dspitch/dsconfig.yaml", stage_config("pitch", "pitch.onnx"))

    write(
      root,
      "dsvariance/dsconfig.yaml",
      stage_config("variance", "variance.onnx") <> "predict_tension: true\n"
    )

    write(
      root,
      "dsvocoder/vocoder.yaml",
      "model: vocoder.onnx\nsample_rate: 44100\nhop_size: 512\n"
    )

    for path <- [
          "acoustic.onnx",
          "linguistic/model.onnx",
          "dsdur/duration.onnx",
          "dspitch/pitch.onnx",
          "dsvariance/variance.onnx",
          "dsvocoder/vocoder.onnx",
          "embeds/Normal.emb"
        ] do
      write(root, path, path)
    end

    root
  end

  defp stage_config(key, model) do
    """
    phonemes: ../phonemes.json
    languages: ../languages.json
    linguistic: ../linguistic/model.onnx
    #{key}: #{model}
    sample_rate: 44100
    hop_size: 512
    """
  end

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
