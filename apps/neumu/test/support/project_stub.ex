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
end
