defmodule Neume.Channels.PitchPin do
  @moduledoc """
  音符级 pitch pin channel（probe 期身份底料，§6.6）。

  payload：兼容旧 `[[tick, midi], ...]` 折线，或 `pitch_curve_v1` 版本化
  Bezier plain map；二者都是绝对 tick + 绝对 MIDI。底料是 probe 物化的
  词内音素序列 `[[lang, phone], ...]`（见 `Neume.Identity`），静态 check
  不做 digest 裁决；投影与签名归 `Neume.Editor` 的挂载/probe 路径。
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

  payload：`[[ph_index, dur_tick], ...]` 音符内稀疏时长钉。底料是 probe
  物化的词内音素序列（pin 下标指向的对象身份）；`ph_index` 越界等
  可表达性校验在消费边界（ScorePlan/Analysis）与 re-patch 手势里。
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
