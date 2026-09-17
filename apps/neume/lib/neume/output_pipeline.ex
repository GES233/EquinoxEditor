defmodule Neume.OutputPipeline do
  @moduledoc "输出干预小图：拓扑决定 duration → pitch，OrchidIntervention 在 producer 输出处裁决。"
  alias Oi.Flowgraph

  def run(producer, state, snapshot, pins, globals, track_id) do
    parts = Neume.Output.split(pins)
    legacy = Map.new(parts, fn {channel, part} -> {channel, part.legacy} end)
    opts = [producer: producer, state: state]

    graph =
      Flowgraph.new_flowchart()
      |> Flowgraph.add_step(__MODULE__.Duration, opts: opts)
      |> Flowgraph.add_step(__MODULE__.Pitch, opts: opts)
      |> Flowgraph.add_step(__MODULE__.Result)
      |> Flowgraph.connect({:output_duration, :packet}, {:output_pitch, :duration})
      |> Flowgraph.connect({:output_pitch, :packet}, {:output_result, :pitch})

    with {:ok, compiled} <- Oi.compile(graph),
         {:ok, result} <-
           Oi.execute(compiled,
             data: %{
               output_duration: %{
                 input: %{snapshot: snapshot, pins: legacy, globals: globals, track_id: track_id}
               },
               output_pitch: %{duration: {Neume.Output, parts.duration.output}},
               output_result: %{pitch: {Neume.Output, parts.pitch.output}}
             },
             orchid_adapters: [&Oi.Adapters.orchid_intervention/1]
           ),
         {:ok, packet} <- Oi.Result.reify(result, {:output_result, :packet}) do
      {:ok, packet}
    else
      {:error, reason} -> {:error, Neume.Engine.OrchidError.slim(reason)}
    end
  end

  defmodule Duration do
    use Oi.Step, name: :output_duration
    manifest(inputs: [:input], outputs: [packet: :any])

    routine input, opts do
      case opts[:producer].output_duration(opts[:state], input) do
        {:ok, packet} -> ok(packet)
        {:error, reason} -> err(reason)
      end
    end
  end

  defmodule Pitch do
    use Oi.Step, name: :output_pitch
    manifest(inputs: [:duration], outputs: [packet: :any])

    routine duration, opts do
      case opts[:producer].output_pitch(opts[:state], duration) do
        {:ok, packet} ->
          ok(packet)

        {:error, reason} ->
          # 下游模型失败不能抹掉已取得的 duration；提取仍可编辑上游，check/render 继续失败。
          entry = %{kind: :model, stage: :output, channel: :pitch, reason: reason}

          ok(
            Map.put(
              %{duration | channel: :pitch, values: [], entries: duration.entries ++ [entry]},
              :available,
              false
            )
          )
      end
    end
  end

  defmodule Result do
    use Oi.Step, name: :output_result
    manifest(inputs: [:pitch], outputs: [packet: :any])

    routine pitch, _opts do
      ok(pitch)
    end
  end
end
