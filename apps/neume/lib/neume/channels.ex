defmodule Neume.Channels.PitchPin do
  @moduledoc """
  音符级 pitch pin channel（probe 期身份底料，§6.6）。

  payload：兼容旧 `[[tick, midi], ...]` 折线（`pitch_points_v1`），或
  `pitch_curve_v1` 版本化 Bezier plain map；二者都是绝对 tick + 绝对
  MIDI，carrier 为 `Pin<S>`（`:score`）。迁移期底座不变：两种 payload
  继续签 `pin_input_v1` 输入事实底料（歌词/显式音素/melisma 归属/声库
  摘要，见 `Neume.Identity`），静态 check 不做 digest 裁决；投影与签名
  归 `Neume.Editor` 的挂载路径。v2（`score_pitch_v2` / `note_tick`
  transport）见 `design-2026-09-pin-carriers` 批次 B。
  """

  @behaviour Coconut.Render.Channel
  @behaviour Neume.Pin.Semantics

  alias Coconut.Edit.Patch
  alias Neume.Pin.{Context, Descriptor, Schema}

  @impl Coconut.Render.Channel
  def projection(_ws, _patch), do: {:error, :probe_stage_channel}

  @impl Coconut.Render.Channel
  def target(%Patch{anchor: %Tamale.Anchor.Ordinal{refs: [id | _]}}), do: {:port, id, :pitch}

  @impl Coconut.Render.Channel
  def resolve_stage, do: :probe

  @impl Neume.Pin.Semantics
  def describe(payload) do
    with {:ok, schema} <- Schema.pitch_payload(payload) do
      {:ok,
       %Descriptor{
         payload_schema: schema,
         base_schema: Schema.base_pin_input_v1(),
         carrier: :score
       }}
    end
  end

  @impl Neume.Pin.Semantics
  def base(%Context{} = context, anchor, _descriptor, _payload),
    do: Neume.Identity.legacy_base(context, anchor)

  # 绝对 tick 点不索引音素，恒可表达（span 合法性在消费边界复核）。
  @impl Neume.Pin.Semantics
  def expressible?(_context, _anchor, _descriptor, _payload), do: :ok

  # Pin<S>：可表达性不依赖 probe 物化序列。
  @impl Neume.Pin.Semantics
  def requires_probe?(_descriptor, _payload), do: false
end

defmodule Neume.Channels.DurationPin do
  @moduledoc """
  逐音素 duration pin channel（probe 期身份底料，§6.6）。

  payload：`[[ph_index, dur_tick], ...]` 音符内稀疏时长钉
  （`phoneme_duration_v1`），carrier 为 `Pin<Co<S,Ph>>`
  （`:correspondence`——同时引用音素 segment 与谱面 tick 预算）。迁移期
  底座不变：继续签 `pin_input_v1` 输入事实底料（见 `Neume.Identity`）；
  `ph_index` 越界等可表达性校验在消费边界（ScorePlan/Analysis）与
  re-patch 手势里（后者读 `Context.legacy_probe` 的 probe 物化词内音素
  序列）。stable segment ref（`phoneme_duration_v2`）见
  `design-2026-09-pin-carriers` 批次 D。
  """

  @behaviour Coconut.Render.Channel
  @behaviour Neume.Pin.Semantics

  alias Coconut.Edit.Patch
  alias Neume.Pin.{Context, Descriptor, Schema}

  @impl Coconut.Render.Channel
  def projection(_ws, _patch), do: {:error, :probe_stage_channel}

  @impl Coconut.Render.Channel
  def target(%Patch{anchor: %Tamale.Anchor.Ordinal{refs: [id | _]}}),
    do: {:port, id, :duration}

  @impl Coconut.Render.Channel
  def resolve_stage, do: :probe

  @impl Neume.Pin.Semantics
  def describe(payload) do
    with {:ok, schema} <- Schema.duration_payload(payload) do
      {:ok,
       %Descriptor{
         payload_schema: schema,
         base_schema: Schema.base_pin_input_v1(),
         carrier: :correspondence
       }}
    end
  end

  @impl Neume.Pin.Semantics
  def base(%Context{} = context, anchor, _descriptor, _payload),
    do: Neume.Identity.legacy_base(context, anchor)

  # 所有 pin 下标须在 probe 物化序列（legacy_probe）界内。
  @impl Neume.Pin.Semantics
  def expressible?(%Context{} = context, anchor, _descriptor, durations) do
    with {:ok, note_id} <- probe_note_id(anchor),
         {:ok, fresh} <- probe_sequence(context, note_id) do
      check_indices(durations, fresh)
    end
  end

  defp probe_note_id(%Tamale.Anchor.Ordinal{refs: [note_id | _]}), do: {:ok, note_id}
  defp probe_note_id(other), do: {:error, {:unsupported_anchor, other}}

  defp probe_sequence(%Context{legacy_probe: nil}, note_id),
    do: {:error, {:unknown_note, note_id}}

  defp probe_sequence(%Context{legacy_probe: probe}, note_id) do
    case Map.fetch(probe, note_id) do
      {:ok, sequence} -> {:ok, sequence}
      :error -> {:error, {:unknown_note, note_id}}
    end
  end

  defp check_indices(durations, fresh) when is_list(durations) do
    Enum.reduce_while(durations, :ok, fn
      [index, _ticks], :ok when is_integer(index) and index >= 0 ->
        if index < length(fresh),
          do: {:cont, :ok},
          else: {:halt, {:error, {:phoneme_index_out_of_range, index, length(fresh)}}}

      other, :ok ->
        {:halt, {:error, {:invalid_duration_payload, other}}}
    end)
  end

  # 旧 duration payload 以裸 `ph_index` 引用 probe 物化序列，必须 probe。
  @impl Neume.Pin.Semantics
  def requires_probe?(_descriptor, _payload), do: true
end
