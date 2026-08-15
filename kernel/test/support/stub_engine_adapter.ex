defmodule Equinox.Kernel.StubEngineAdapter do
  @moduledoc """
  测试用 stub 引擎适配器：只接 `:phoneme_timing` channel 的伪引擎
  （`Equinox.Kernel.EngineAdapter` 的参考最小实现）。

  config 形状（对 kernel 不透明，此处为测试约定）：

      %{voicebank_id: "stub_vb", engine_version: "0.0.1", channels: [:phoneme_timing]}

  check 侧 spec projection 演示「单一 canonical 实现」纪律：从 RenderRequest
  取音符 + span，委派 `PhonemeTiming.base_for/2`（与挂载侧 `projection/2`
  同一实现），再用 `Channel.stamp_base/2` 盖引擎版本戳。
  """

  @behaviour Equinox.Kernel.EngineAdapter

  alias EquinoxDomain.Command.RenderRequest
  alias EquinoxDomain.Port.Channel
  alias EquinoxDomain.Port.Channels.PhonemeTiming

  @impl true
  def engine_key(config), do: "#{config.voicebank_id}@#{config.engine_version}"

  @impl true
  def channels(config) do
    key = engine_key(config)

    config
    |> Map.get(:channels, [:phoneme_timing])
    |> Map.new(fn
      :phoneme_timing ->
        {:phoneme_timing,
         %{
           projection: fn %RenderRequest{} = request, patch ->
             with {:ok, note_id} <- anchor_note_id(patch.anchor),
                  {:ok, note, span} <- fetch_request_note(request, note_id),
                  {:ok, base} <- PhonemeTiming.base_for(note, span) do
               {:ok, Channel.stamp_base(base, key)}
             end
           end,
           target: PhonemeTiming.target()
         }}
    end)
  end

  @impl true
  def timing_spec(_config), do: {:ok, %{frame_rate: 100, hop: 512}}

  @impl true
  def globals(_config), do: %{}

  @impl true
  def adoptables(_config), do: [:phoneme_timing]

  defp anchor_note_id(%Tamale.Anchor.Ordinal{refs: [id | _]}), do: {:ok, id}
  defp anchor_note_id(%Tamale.Anchor.Relative{ref: id}), do: {:ok, id}
  defp anchor_note_id(_other), do: {:error, :unsupported_anchor}

  defp fetch_request_note(%RenderRequest{notes: notes}, note_id) do
    case Enum.find(notes, fn {id, _note, _span} -> id == note_id end) do
      {_id, note, span} -> {:ok, note, span}
      nil -> {:error, {:note_not_found, note_id}}
    end
  end
end
