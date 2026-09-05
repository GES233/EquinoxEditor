defmodule Neume.Channels.PitchPin do
  @moduledoc """
  音符级 pitch pin channel（probe 期身份底料，§6.6）。

  payload：兼容旧 `[[tick, midi], ...]` 折线，或 `pitch_curve_v1` 版本化
  Bezier plain map；二者都是绝对 tick + 绝对 MIDI。底料是输入事实签名
  （歌词/显式音素/melisma 归属/声库摘要，见 `Neume.Identity`），静态
  check 不做 digest 裁决；投影与签名归 `Neume.Editor` 的挂载路径。
  """

  @behaviour Coconut.Render.Channel

  alias Coconut.Edit.Patch

  @impl true
  def projection(_ws, _patch), do: {:error, :probe_stage_channel}

  @impl true
  def target(%Patch{anchor: %Tamale.Anchor.Ordinal{refs: [id | _]}}), do: {:port, id, :pitch}

  @impl true
  def resolve_stage, do: :probe
end

defmodule Neume.Channels.DurationPin do
  @moduledoc """
  逐音素 duration pin channel（probe 期身份底料，§6.6）。

  payload：`[[ph_index, dur_tick], ...]` 音符内稀疏时长钉。底料是输入
  事实签名（见 `Neume.Identity`）；`ph_index` 越界等可表达性校验在
  消费边界（ScorePlan/Analysis）与 re-patch 手势里（后者需要 probe
  物化的词内音素序列长度）。
  """

  @behaviour Coconut.Render.Channel

  alias Coconut.Edit.Patch

  @impl true
  def projection(_ws, _patch), do: {:error, :probe_stage_channel}

  @impl true
  def target(%Patch{anchor: %Tamale.Anchor.Ordinal{refs: [id | _]}}),
    do: {:port, id, :duration}

  @impl true
  def resolve_stage, do: :probe
end
