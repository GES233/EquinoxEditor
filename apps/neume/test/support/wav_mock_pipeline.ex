defmodule Neume.Engine.WavMockPipeline do
  @moduledoc """
  测试用 pipeline：分析/检查语义全部委托 `Neume.Engine.MockPipeline`，
  仅把 render 换成确定性的正弦 WAV 输出，让多轨混音图与节点缓存测试有
  真实制品可消费。同一 `(track_id, frame_count)` 的输出字节恒定，
  因此内容摘要在多次渲染间稳定。
  """

  @samples_per_frame 100
  @sample_rate 44_100
  @amplitude 8_000

  defdelegate compile(opts), to: Neume.Engine.MockPipeline
  defdelegate engine_config(state, track_id), to: Neume.Engine.MockPipeline
  defdelegate voicebank_digest(state), to: Neume.Engine.MockPipeline
  defdelegate phonology_digest(state), to: Neume.Engine.MockPipeline
  defdelegate checked_pins(pins), to: Neume.Engine.MockPipeline

  defdelegate analyze_phrases(state, snapshot, pins, globals, track_id),
    to: Neume.Engine.MockPipeline

  defdelegate analyze(state, snapshot, pins, globals, track_id),
    to: Neume.Engine.MockPipeline

  defdelegate phonemes(state, snapshot, track_id), to: Neume.Engine.MockPipeline

  defdelegate output_packets(state, snapshot, pins, globals, track_id),
    to: Neume.Engine.MockPipeline

  defdelegate lower_pins(state, snapshot, resolved, track_id),
    to: Neume.Engine.MockPipeline

  def render(state, snapshot, _pins, globals, track_id) do
    with {:ok, artifact} <-
           Neume.Engine.MockPipeline.render(state, snapshot, %{}, globals, track_id) do
      {:ok, to_wav(artifact, track_id)}
    end
  end

  def render_checked(state, snapshot, _checked, globals, track_id) do
    with {:ok, artifact} <-
           Neume.Engine.MockPipeline.render(state, snapshot, %{}, globals, track_id) do
      {:ok, to_wav(artifact, track_id)}
    end
  end

  defp to_wav(%Neume.RenderArtifact{} = artifact, track_id) do
    sample_count = artifact.frame_count * @samples_per_frame

    # 内容随 (track_id, pitch 序列, 帧数) 变化：编辑音符后摘要必须改变。
    seed = :erlang.phash2({track_id, artifact.midi, artifact.frame_count})
    phase = rem(seed, 12) * 0.5
    freq = 200 + rem(seed, 7) * 20

    pcm =
      for i <- 0..(sample_count - 1)//1, into: <<>> do
        value =
          (@amplitude * :math.sin(i / @sample_rate * 2 * :math.pi() * freq + phase)) |> round()

        <<value::little-signed-16>>
      end

    path =
      Path.join(
        System.tmp_dir!(),
        "neume-wav-mock-#{track_id}-#{System.unique_integer([:positive, :monotonic])}.wav"
      )

    :ok = Neume.Wav.write(path, pcm, @sample_rate)

    %{
      artifact
      | format: :wav,
        path: path,
        sample_rate: @sample_rate,
        sample_count: sample_count,
        duration_sec: sample_count / @sample_rate
    }
  end
end
