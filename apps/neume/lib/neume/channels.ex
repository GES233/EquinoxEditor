defmodule Neume.Channels.PitchPin do
  @moduledoc """
  音符级 pitch pin channel（probe 期身份底料，§6.6）。

  payload 三形（`describe/1` 按 payload 分派）：

  - 旧 `[[tick, midi], ...]` 折线（`pitch_points_v1`，绝对 tick）与
    `pitch_curve_v1` Bezier plain map：legacy，继续签 `pin_input_v1`
    输入事实底料（歌词/显式音素/melisma 归属/声库摘要，见
    `Neume.Identity`），行为不变；
  - `score_pitch_v2` envelope（批次 B）：`note_tick` 相对坐标，签
    `score_region_v1` 底料——只钉 track/note 与坐标系，不含歌词、
    音素、声库与 runtime digest；改词、换声库、拖动均不炸，merge 锚
    重定签（origin 变化）与跨轨移动（track 分量变化）会炸，由
    repatch 显式重签。survival matrix 见设计文档批次 B。

  静态 check 不做 digest 裁决；投影与签名归 `Neume.Editor` 的挂载路径。
  """

  @behaviour Coconut.Render.Channel
  @behaviour Neume.Pin.Semantics

  alias Coconut.Edit.{Patch, Track}
  alias Neume.Pin.{Context, Descriptor, Schema}

  @score_pitch_v2 Schema.score_pitch_v2()
  @score_region_v1 Schema.base_score_region_v1()

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
         base_schema: base_schema(schema),
         carrier: :score
       }}
    end
  end

  defp base_schema(@score_pitch_v2), do: @score_region_v1
  defp base_schema(_legacy), do: Schema.base_pin_input_v1()

  # v2 底料：谱面区域事实（track + 锚定音符 + 坐标系）。不含绝对起点
  # （拖动跟随）、不含歌词/音素/声库（Pin<S> 与语音学解耦）。
  @impl Neume.Pin.Semantics
  def base(%Context{} = context, anchor, %Descriptor{base_schema: @score_region_v1}, _payload),
    do: score_region_base(context, anchor)

  def base(%Context{} = context, anchor, _descriptor, _payload),
    do: Neume.Identity.legacy_base(context, anchor)

  defp score_region_base(%Context{} = context, %Tamale.Anchor.Ordinal{refs: [note_id | _]}) do
    case Track.latest_span(context.track, note_id) do
      nil ->
        {:error, {:unknown_note, note_id}}

      _span ->
        {:ok,
         %{
           schema: @score_region_v1,
           coordinates: Schema.note_tick(),
           track: context.track_id,
           note: note_id
         }}
    end
  end

  defp score_region_base(%Context{}, other), do: {:error, {:unsupported_anchor, other}}

  # v2：偏移须落在当前锚定音符 span 内（trim/split 后越界 → repatch 降级；
  # 消费边界另有 loud 复核）。legacy 绝对 tick 点恒可表达（span 合法性在
  # 消费边界复核）。
  @impl Neume.Pin.Semantics
  def expressible?(
        %Context{} = context,
        anchor,
        %Descriptor{payload_schema: @score_pitch_v2},
        payload
      ),
      do: offsets_expressible?(context, anchor, payload)

  def expressible?(_context, _anchor, _descriptor, _payload), do: :ok

  defp offsets_expressible?(%Context{} = context, %Tamale.Anchor.Ordinal{refs: [note_id | _]}, %{
         values: values
       }) do
    case Track.latest_span(context.track, note_id) do
      nil ->
        {:error, {:unknown_note, note_id}}

      {start_tick, end_tick} ->
        span = end_tick - start_tick

        Enum.reduce_while(values, :ok, fn
          [offset, midi], :ok when is_integer(offset) and is_number(midi) ->
            if offset >= 0 and offset < span,
              do: {:cont, :ok},
              else: {:halt, {:error, {:pitch_offset_out_of_range, note_id, offset, span}}}

          other, :ok ->
            {:halt, {:error, {:invalid_score_pitch_v2_value, other}}}
        end)
    end
  end

  defp offsets_expressible?(%Context{}, other, _payload),
    do: {:error, {:unsupported_anchor, other}}

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
