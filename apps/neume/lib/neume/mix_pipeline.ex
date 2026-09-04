defmodule Neume.MixPipeline do
  @moduledoc """
  Neume-owned 多轨 Oi 图：逐轨 gain/pan/mute → 求和 → master 限幅 → WAV 导出。
  输入轨道必须已经由各自的声库 pipeline 渲染为 WAV。
  """

  alias Neume.MixPipeline.Steps.{Export, Master, Mix, TrackGainPan}
  alias Oi.Flowgraph

  @spec compile(keyword()) :: {:ok, Oi.Compiled.t()} | {:error, term()}
  def compile(opts \\ []) do
    graph =
      Flowgraph.new_flowchart()
      |> Flowgraph.add_step(TrackGainPan)
      |> Flowgraph.add_step(Mix)
      |> Flowgraph.add_step(Master)
      |> Flowgraph.add_step(Export,
        opts: [output_dir: Keyword.get(opts, :output_dir, "tmp/renders")]
      )
      |> Flowgraph.connect({:track_gain_pan, :prepared_tracks}, {:mix, :tracks})
      |> Flowgraph.connect({:mix, :mix}, {:master, :mix})
      |> Flowgraph.connect({:master, :master}, {:export, :master})

    Oi.compile(graph)
  end

  @spec run(Oi.Compiled.t(), [map()]) :: {:ok, Neume.MixArtifact.t()} | {:error, term()}
  def run(compiled, tracks) do
    with {:ok, result} <- Oi.execute(compiled, data: %{track_gain_pan: %{tracks: tracks}}) do
      Oi.Result.reify(result, {:export, :artifact})
    end
  end
end

defmodule Neume.MixPipeline.Steps.TrackGainPan do
  @moduledoc false
  use Oi.Step, name: :track_gain_pan

  manifest(inputs: [:tracks], outputs: [prepared_tracks: :any])

  routine tracks, _opts do
    case Enum.reduce_while(tracks, {:ok, []}, &prepare_track/2) do
      {:ok, prepared} -> ok(Enum.reverse(prepared))
      {:error, _} = error -> error
    end
  end

  defp prepare_track(%{artifact: %{path: path}, mix: mix, track_id: track_id}, {:ok, acc}) do
    with :ok <- Neume.TrackConfig.validate_mix(mix),
         {:ok, clip} <- Neume.Wav.read(path) do
      {left, right} = stereo(clip.samples, mix)

      {:cont,
       {:ok,
        [%{track_id: track_id, sample_rate: clip.sample_rate, left: left, right: right} | acc]}}
    else
      {:error, reason} -> {:halt, {:error, {:track_mix_failed, track_id, reason}}}
    end
  end

  defp prepare_track(track, _acc), do: {:halt, {:error, {:invalid_track_artifact, track}}}

  defp stereo(samples, %{mute: true}), do: {silence(samples), silence(samples)}

  defp stereo(samples, %{gain: gain, pan: pan}) do
    left_gain = gain * if(pan > 0, do: 1.0 - pan, else: 1.0)
    right_gain = gain * if(pan < 0, do: 1.0 + pan, else: 1.0)
    {scale(samples, left_gain), scale(samples, right_gain)}
  end

  defp silence(samples), do: :binary.copy(<<0, 0>>, div(byte_size(samples), 2))

  defp scale(samples, gain) do
    for <<sample::little-signed-16 <- samples>>, into: <<>> do
      value = sample |> Kernel.*(gain) |> round() |> max(-32_768) |> min(32_767)
      <<value::little-signed-16>>
    end
  end
end

defmodule Neume.MixPipeline.Steps.Mix do
  @moduledoc false
  use Oi.Step, name: :mix

  manifest(inputs: [:tracks], outputs: [mix: :any])

  routine tracks, _opts do
    case mix(tracks) do
      {:ok, value} -> ok(value)
      {:error, _} = error -> error
    end
  end

  defp mix([]), do: {:error, :no_audible_tracks}

  defp mix([first | _] = tracks) do
    sample_rate = first.sample_rate

    if Enum.all?(tracks, &(&1.sample_rate == sample_rate)) do
      sample_count = Enum.max(Enum.map(tracks, &div(byte_size(&1.left), 2)))
      left = sum_channel(tracks, :left, sample_count)
      right = sum_channel(tracks, :right, sample_count)

      {:ok,
       %{
         sample_rate: sample_rate,
         sample_count: sample_count,
         left: left,
         right: right,
         track_ids: Enum.map(tracks, & &1.track_id)
       }}
    else
      {:error, {:inconsistent_sample_rates, Enum.map(tracks, &{&1.track_id, &1.sample_rate})}}
    end
  end

  defp sum_channel(tracks, channel, count) do
    Enum.reduce(0..(count - 1), <<>>, fn index, acc ->
      sum = Enum.sum(Enum.map(tracks, &sample_at(Map.fetch!(&1, channel), index)))
      <<acc::binary, sum::little-signed-32>>
    end)
  end

  defp sample_at(samples, index) when index * 2 < byte_size(samples) do
    <<value::little-signed-16>> = binary_part(samples, index * 2, 2)
    value
  end

  defp sample_at(_samples, _index), do: 0
end

defmodule Neume.MixPipeline.Steps.Master do
  @moduledoc false
  use Oi.Step, name: :master

  manifest(inputs: [:mix], outputs: [master: :any])

  routine mix, _opts do
    master =
      mix |> Map.put(:samples, interleave(mix.left, mix.right)) |> Map.drop([:left, :right])

    ok(master)
  end

  defp interleave(left, right), do: interleave(left, right, <<>>)
  defp interleave(<<>>, <<>>, acc), do: acc

  defp interleave(
         <<l::little-signed-32, left::binary>>,
         <<r::little-signed-32, right::binary>>,
         acc
       ) do
    l = max(-32_768, min(32_767, l))
    r = max(-32_768, min(32_767, r))
    interleave(left, right, <<acc::binary, l::little-signed-16, r::little-signed-16>>)
  end
end

defmodule Neume.MixPipeline.Steps.Export do
  @moduledoc false
  use Oi.Step, name: :export

  manifest(inputs: [:master], outputs: [artifact: :any])

  routine master, opts do
    directory = Keyword.fetch!(opts, :output_dir)

    path =
      Path.expand(
        Path.join(directory, "mix_#{System.unique_integer([:positive, :monotonic])}.wav")
      )

    case Neume.Wav.write_stereo(path, master.samples, master.sample_rate) do
      :ok ->
        ok(%Neume.MixArtifact{
          path: path,
          sample_rate: master.sample_rate,
          sample_count: master.sample_count,
          duration_sec: master.sample_count / master.sample_rate,
          track_ids: master.track_ids
        })

      {:error, _} = error ->
        error
    end
  end
end
