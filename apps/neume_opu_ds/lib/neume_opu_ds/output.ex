defmodule NeumeOpuDs.Output do
  @moduledoc "DiffSinger 输出 producer：大张量留在 worker，只传已有帧级分析结果。"
  alias NeumeOpuDs.Pipeline.Steps

  def packet(state, snapshot, pins, globals, track_id),
    do: Neume.OutputPipeline.run(__MODULE__, state, snapshot, pins, globals, track_id)

  def packets(state, snapshot, pins, globals, track_id) do
    with {:ok, phrases} <- Neume.Phrase.split(snapshot, track_id, pins) do
      Enum.reduce_while(phrases, {:ok, []}, fn phrase, {:ok, acc} ->
        case packet(state, phrase.snapshot, phrase.pins, globals, track_id) do
          {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
          error -> {:halt, error}
        end
      end)
    end
  end

  def output_duration(state, input) do
    # Stock 的随机输出不能作为可重放底料；实验 GPU 路径同样不承诺精确重放。
    reproducible =
      state.client != NeumeOpuDs.Worker or
        (state.worker_config.fp_manifest != nil and state.worker_config.backend == :cpu)

    with true <- reproducible,
         {:ok, plan} <-
           Steps.ScorePlan.build(
             input.snapshot,
             input.pins.pitch,
             input.pins.duration,
             input.globals,
             input.track_id,
             frame_rate: state.manifest.timing.frame_rate
           ),
         {:ok, probe} <-
           Steps.Analysis.probe(
             plan,
             [client: state.client, worker_config: state.worker_config],
             "duration"
           ) do
      {:ok,
       %{
         channel: :duration,
         values: probe.ph_dur,
         segments: probe.boundaries,
         frame_rate: state.manifest.timing.frame_rate,
         origin_sec: probe.origin_sec,
         lead_in_sec: probe.lead_in_sec,
         entries: [],
         projections: %{},
         context: %{plan: plan, probe: probe}
       }}
    else
      false -> {:error, :replayable_cpu_runtime_required}
      error -> error
    end
  end

  def output_pitch(state, duration) do
    %{plan: plan, probe: probe} = duration.context

    with {:ok, result} <-
           state.client.call(
             %{
               action: "pitch",
               words: probe.words,
               groups: probe.groups,
               overrides: probe.overrides,
               globals: plan.globals,
               ph_dur: duration.values
             },
             state.worker_config
           ),
         values when is_list(values) <- result["pitch_pred_midi"],
         true <- length(values) == Enum.sum(duration.values) and Enum.all?(values, &is_number/1) do
      probe = %{
        probe
        | ph_dur: duration.values,
          boundaries: duration.segments,
          pitch_pred_midi: values,
          total_frames: length(values)
      }

      {:ok, %{duration | channel: :pitch, values: values, context: %{plan: plan, probe: probe}}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_pitch_output}
    end
  end

  def checked(packet) do
    %{plan: plan, probe: probe} = packet.context
    %{plan: plan, probe: %{probe | pitch_pred_midi: packet.values}}
  end
end
