defmodule EquinoxDomain.LayerChunk do
  @moduledoc """
  时间轴上的数据片段——Track 中所有随时间变化的数据的最小存储单元。

  无论来源是用户手画还是引擎产出被采纳，都通过 `source` 区分。
  同一 channel 内，`:adopted` 覆盖 `:user` 的重叠区间。

  `payload` 为具体数据，语义由所在的 `Channel.channel()` 决定。
  """

  alias EquinoxDomain.Timeline.Tick

  @type source :: :user | :adopted

  @type t :: %__MODULE__{
          start_tick: Tick.numeric_tick(),
          end_tick: Tick.numeric_tick(),
          payload: term(),
          source: source()
        }

  use EquinoxDomain.Util.Object,
    keys: [
      :start_tick,
      :end_tick,
      :payload,
      source: :user
    ]

  @doc """
  检查两个 chunk 是否在时间上有重叠（左闭右开）。

  ## Examples

      iex> LayerChunk.overlaps?(%LayerChunk{start_tick: 0, end_tick: 480}, %LayerChunk{start_tick: 240, end_tick: 960})
      true

      iex> LayerChunk.overlaps?(%LayerChunk{start_tick: 0, end_tick: 480}, %LayerChunk{start_tick: 480, end_tick: 960})
      false
  """
  @spec overlaps?(t(), t()) :: boolean()
  def overlaps?(
        %__MODULE__{start_tick: a0, end_tick: a1},
        %__MODULE__{start_tick: b0, end_tick: b1}
      ) do
    a0 < b1 && b0 < a1
  end
end
