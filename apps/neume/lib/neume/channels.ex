defmodule Neume.Channels.PitchPin do
  @moduledoc """
  音符级 pitch pin channel（probe 期身份底料，§6.6）。

  payload 四形（`describe/1` 按 payload 分派）：

  - 旧 `[[tick, midi], ...]` 折线（`pitch_points_v1`，绝对 tick）与
    `pitch_curve_v1` Bezier plain map：legacy，继续签 `pin_input_v1`
    输入事实底料（歌词/显式音素/melisma 归属/声库摘要，见
    `Neume.Identity`），行为不变；
  - `score_pitch_v2` envelope（批次 B）与 `pitch_curve_v2` Bezier
    envelope（批次 E，anchor 为 `note_tick` 相对坐标、handle 保持相对
    anchor 偏移）：签 `score_region_v1` 底料——只钉 track/note 与坐标系，
    不含歌词、音素、声库与 runtime digest；改词、换声库、拖动均不炸，
    merge 锚重定签（origin 变化）与跨轨移动（track 分量变化）会炸，由
    repatch 显式重签。survival matrix 见设计文档批次 B/E。

  静态 check 不做 digest 裁决；投影与签名归 `Neume.Editor` 的挂载路径。
  """

  @behaviour Coconut.Render.Channel
  @behaviour Neume.Pin.Semantics

  alias Coconut.Edit.{Patch, Track}
  alias Neume.Pin.{Context, Descriptor, Schema}

  @score_pitch_v2 Schema.score_pitch_v2()
  @pitch_curve_v2 Schema.pitch_curve_v2()
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

  defp base_schema(schema) when schema in [@score_pitch_v2, @pitch_curve_v2],
    do: @score_region_v1

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

  # 批次 E：Bezier envelope 只判定 anchor 的 offset_tick 界内（handle 偏移
  # 不做 span 判定，与 legacy `validate_inside` 只查 anchor 同一规则）。
  def expressible?(
        %Context{} = context,
        anchor,
        %Descriptor{payload_schema: @pitch_curve_v2},
        %{points: points}
      )
      when is_list(points) do
    Enum.reduce_while(points, :ok, fn
      %{offset_tick: offset, value: value}, :ok
      when is_integer(offset) and is_number(value) ->
        {:cont, :ok}

      other, :ok ->
        {:halt, {:error, {:invalid_pitch_curve_v2_point, other}}}
    end)
    |> case do
      :ok ->
        offsets_expressible?(context, anchor, %{
          values: Enum.map(points, &[&1.offset_tick, &1.value])
        })

      {:error, _} = error ->
        error
    end
  end

  def expressible?(_context, _anchor, %Descriptor{payload_schema: @pitch_curve_v2}, other),
    do: {:error, {:invalid_pitch_curve_v2, other}}

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

  payload 两形（`describe/1` 按 payload 分派），carrier 均为
  `Pin<Co<S,Ph>>`（`:correspondence`——同时引用音素 segment 与谱面
  tick 预算）：

  - 旧 `[[ph_index, dur_tick], ...]` 点列（`phoneme_duration_v1`）：
    legacy，继续签 `pin_input_v1` 输入事实底料（见 `Neume.Identity`）；
    自 E0a 起仅经读档/兼容路径出现（`Neume.Editor.mount_phoneme_duration/4`
    的 list 入参换算为 v2 envelope 挂载），`ph_index` 越界等可表达性
    校验在消费边界（ScorePlan/Analysis）与 re-patch 手势里（后者读
    `Context.legacy_probe` 的 probe 物化词内音素序列），行为不变；
  - `phoneme_duration_v2` envelope（批次 D）：stable segment ref
    （`%{unit, member, index}`，`Neume.Phonology.Ref`）替代裸
    `ph_index`，签 `phoneme_correspondence_v1` 底料——钉 track/note、
    unit（组头 note_id）与全组输入事实（各成员歌词/显式音素）+
    字典级 phonology digest。改音高、拖动、模型刷新（Stock/Modified
    切换）不炸；改词、词典/G2P 变化、melisma 晋升/断组会炸，repatch
    经 `redirect/4` 按锚定音符的当前 membership 机械重定 ref
    （unit/member 重写、index 不变），映射不成立则降级。
  """

  @behaviour Coconut.Render.Channel
  @behaviour Neume.Pin.Semantics

  alias Coconut.Edit.{Patch, Track}
  alias Neume.Phonology.Ref
  alias Neume.Pin.{Context, Descriptor, Schema}

  @phoneme_duration_v2 Schema.phoneme_duration_v2()
  @correspondence_v1 Schema.base_phoneme_correspondence_v1()

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
         base_schema: base_schema(schema),
         carrier: :correspondence
       }}
    end
  end

  defp base_schema(@phoneme_duration_v2), do: @correspondence_v1
  defp base_schema(_legacy), do: Schema.base_pin_input_v1()

  @impl Neume.Pin.Semantics
  def base(%Context{} = context, anchor, %Descriptor{base_schema: @correspondence_v1}, _payload),
    do: correspondence_base(context, anchor)

  def base(%Context{} = context, anchor, _descriptor, _payload),
    do: Neume.Identity.legacy_base(context, anchor)

  # v2 底料：谱面区域（track/note）+ unit 组成与全组输入事实 + 字典级
  # phonology digest。续音符的序列派生自组头（延续元音取头词元音），
  # 故底料覆盖全组成员而非只锚定音符自身。声库在场但 runtime 未提供
  # phonology digest 时拒绝签名（不静默回退全量摘要）。
  defp correspondence_base(%Context{} = context, %Tamale.Anchor.Ordinal{refs: [note_id | _]}) do
    with :ok <- ensure_phonology_digest(context),
         {:ok, membership} <- fetch_membership(context.track, note_id) do
      notes = Map.new(Track.view(context.track), fn {id, note, _span} -> {id, note} end)

      members =
        context.track
        |> memberships()
        |> Ref.units()
        |> Map.fetch!(membership.head_id)
        |> Enum.map(fn id ->
          note = Map.fetch!(notes, id)
          %{note: id, lyric: note.lyric, phonemes: explicit_phonemes(note)}
        end)

      {:ok,
       %{
         schema: @correspondence_v1,
         track: context.track_id,
         note: note_id,
         unit: membership.head_id,
         members: members,
         phonology_digest: Context.phonology_digest(context)
       }}
    end
  end

  defp correspondence_base(%Context{}, other), do: {:error, {:unsupported_anchor, other}}

  defp ensure_phonology_digest(%Context{} = context) do
    if Context.voicebank_digest(context) != nil and Context.phonology_digest(context) == nil,
      do: {:error, {:missing_phonology_digest, context.track_id}},
      else: :ok
  end

  defp explicit_phonemes(note), do: Map.get(note.metadata || %{}, "phonemes")

  # v2：segment ref 必须指向锚定音符自身（unit/member 与当前 membership
  # 一致）且 index 在 probe 物化序列界内。legacy：所有下标界内。
  @impl Neume.Pin.Semantics
  def expressible?(
        %Context{} = context,
        anchor,
        %Descriptor{payload_schema: @phoneme_duration_v2},
        %{
          values: values
        }
      ) do
    with {:ok, note_id} <- probe_note_id(anchor),
         {:ok, membership} <- fetch_membership(context.track, note_id),
         {:ok, sequence} <- probe_sequence(context, note_id) do
      check_segments(values, note_id, membership, sequence)
    end
  end

  def expressible?(%Context{} = context, anchor, _descriptor, durations) do
    with {:ok, note_id} <- probe_note_id(anchor),
         {:ok, fresh} <- probe_sequence(context, note_id) do
      check_indices(durations, fresh)
    end
  end

  # 组归属漂移后的 payload 机械重写（批次 D）：segment ref 按锚定音符的
  # 当前 membership 重定 unit/member，index 不变；value 形状不完整时
  # 放弃重写（交由降级报告）。重写结果由 repatch 计划再经
  # `expressible?/4` 复核。
  @impl Neume.Pin.Semantics
  def redirect(%Context{} = context, anchor, %Descriptor{payload_schema: @phoneme_duration_v2}, %{
        values: values
      }) do
    with {:ok, note_id} <- probe_note_id(anchor),
         {:ok, membership} <- fetch_membership(context.track, note_id),
         true <- Enum.all?(values, &segment_value?/1) do
      rewritten =
        Enum.map(values, fn value ->
          %{value | segment: Ref.segment(membership, value.segment.index)}
        end)

      {:ok, %{schema: @phoneme_duration_v2, values: rewritten}}
    else
      _other -> :error
    end
  end

  def redirect(%Context{}, _anchor, _descriptor, _payload), do: :error

  defp segment_value?(%{
         segment: %{unit: _unit, member: member, index: index},
         duration_tick: ticks
       })
       when is_integer(member) and member >= 0 and is_integer(index) and index >= 0 and
              is_integer(ticks) and ticks > 0,
       do: true

  defp segment_value?(_other), do: false

  defp check_segments(values, note_id, membership, sequence) do
    Enum.reduce_while(values, :ok, fn
      %{segment: %{unit: unit, member: member, index: index}, duration_tick: ticks}, :ok
      when is_integer(member) and member >= 0 and is_integer(index) and index >= 0 and
             is_integer(ticks) and ticks > 0 ->
        ref = %{unit: unit, member: member, index: index}

        cond do
          unit != membership.head_id or member != membership.member_index ->
            {:halt, {:error, {:segment_ref_mismatch, note_id, ref}}}

          index >= length(sequence) ->
            {:halt, {:error, {:phoneme_index_out_of_range, index, length(sequence)}}}

          true ->
            {:cont, :ok}
        end

      other, :ok ->
        {:halt, {:error, {:invalid_duration_value, other}}}
    end)
  end

  defp probe_note_id(%Tamale.Anchor.Ordinal{refs: [note_id | _]}), do: {:ok, note_id}
  defp probe_note_id(other), do: {:error, {:unsupported_anchor, other}}

  defp memberships(%Track{} = track), do: Ref.track_memberships(track)

  defp fetch_membership(track, note_id) do
    case Map.fetch(memberships(track), note_id) do
      {:ok, membership} -> {:ok, membership}
      :error -> {:error, {:unknown_note, note_id}}
    end
  end

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

  # duration pin 引用 probe 物化序列（legacy 裸下标 / v2 segment ref 的
  # 界内判定），必须 probe。
  @impl Neume.Pin.Semantics
  def requires_probe?(_descriptor, _payload), do: true
end
