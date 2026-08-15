defmodule Equinox.Kernel.StubEngineAdapter do
  @moduledoc """
  测试用 stub 引擎适配器：只接 `:phoneme_timing` channel 的伪引擎
  （`Equinox.Kernel.EngineAdapter` 的参考最小实现）。

  config 形状（对 kernel 不透明，此处为测试约定）：

      %{voicebank_id: "stub_vb", engine_version: "0.0.1", channels: [:phoneme_timing]}

  或直接挂声库描述符（约定用法，见 `Equinox.Kernel.Voicebank`）：

      %{voicebank: %Voicebank{id: "stub_vb", engine_version: "0.0.1",
                              capabilities: %{supported_channels: [:phoneme_timing]},
                              timing: %{frame_rate: 100, hop: 512}, ...}}

  `:voicebank` 存在时 `engine_key` / channel 列表 / `timing_spec` 一律从
  描述符派生（描述符优先于平铺键）。可选平铺键：`:globals`（校验规则
  声明，缺省 `%{}`）、`:adoptables`（可采纳 channel 列表，缺省
  `[:phoneme_timing]`）。

  check 侧 spec projection 演示「单一 canonical 实现」纪律：从 RenderRequest
  取音符 + span，委派 `PhonemeTiming.base_for/2`（与挂载侧 `projection/2`
  同一实现），再用 `Channel.stamp_base/2` 盖引擎版本戳。
  """

  @behaviour Equinox.Kernel.EngineAdapter

  alias Equinox.Kernel.Voicebank
  alias EquinoxDomain.Command.RenderRequest
  alias EquinoxDomain.Port.Channel
  alias EquinoxDomain.Port.Channels.PhonemeTiming

  @impl true
  def engine_key(config) do
    case Map.get(config, :voicebank) do
      %Voicebank{} = vb -> Voicebank.engine_key(vb)
      _flat -> "#{config.voicebank_id}@#{config.engine_version}"
    end
  end

  @impl true
  def channels(config) do
    key = engine_key(config)

    config
    |> channel_list()
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

  # channel 列表：描述符的 capabilities.supported_channels 优先于平铺 :channels
  defp channel_list(config) do
    case Map.get(config, :voicebank) do
      %Voicebank{capabilities: %{supported_channels: channels}} -> channels
      _flat -> Map.get(config, :channels, [:phoneme_timing])
    end
  end

  @impl true
  def timing_spec(config) do
    case Map.get(config, :voicebank) do
      %Voicebank{timing: timing} when map_size(timing) > 0 -> {:ok, timing}
      _flat -> {:ok, %{frame_rate: 100, hop: 512}}
    end
  end

  @impl true
  def globals(config), do: Map.get(config, :globals, %{})

  @impl true
  def adoptables(config), do: Map.get(config, :adoptables, [:phoneme_timing])

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
