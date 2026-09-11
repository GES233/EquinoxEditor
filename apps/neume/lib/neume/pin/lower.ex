defmodule Neume.Pin.Lower do
  @moduledoc """
  `Neume.Pin.Resolved` 的默认 lowering（`design-2026-09-pin-carriers` §4）。

  runtime 的 `Neume.Runtime.lower_pins/4` 可直接委托本模块：把裁决侧
  构造的 engine-independent Resolved 列表降为现有 pins map
  （`%{pitch: %{note_id => payload}, duration: %{note_id => payload}}`），
  供 `analyze_phrases/5` / `render/5` 消费。

  - legacy payload（`pitch_points_v1` / `pitch_curve_v1` /
    `phoneme_duration_v1`）原样透传——消费边界（ScorePlan 等）已理解
    这些形状；
  - `score_pitch_v2`（`note_tick`）按 snapshot 的音符起点平移为绝对
    tick 点列，降为 `pitch_points_v1` 同形；span 合法性仍由消费边界
    复核（与 legacy 同一错误形状），lowering 不吞点、不裁点；
  - `phoneme_duration_v2`（批次 D）：segment ref 降为成员自身序列内
    下标（`[[index, duration_tick]]`，与 `phoneme_duration_v1` 同形）——
    ref 的 unit/member 必须与锚定音符在 snapshot 中派生的 membership
    一致（不一致即 `{:segment_ref_mismatch, note_id, ref}` loud 报错）；
    index 界内判定由消费边界按 legacy 同一规则复核（lowering 不做
    probe，不知道序列长度）；
  - 未知 schema 返回 `{:error, {:unsupported_pin_schema, schema}}`，
    不静默猜解。
  """

  alias Coconut.Render.Engine.Snapshot
  alias Neume.Phonology.Ref
  alias Neume.Pin.{Descriptor, Resolved, Schema}
  alias Neume.Syllable

  @score_pitch_v2 Schema.score_pitch_v2()
  @phoneme_duration_v2 Schema.phoneme_duration_v2()

  @spec lower([Resolved.t()], Snapshot.t(), term()) :: {:ok, map()} | {:error, term()}
  def lower(resolved, %Snapshot{} = snapshot, track_id) when is_list(resolved) do
    with {:ok, view} <- Map.fetch(snapshot.tracks, track_id) do
      derived = %{
        spans: Map.new(view.elements, fn {id, _note, span} -> {id, span} end),
        memberships: memberships(view.elements)
      }

      resolved
      |> Enum.reduce_while({:ok, %{}}, fn pin, {:ok, acc} ->
        with {:ok, note_id} <- note_id(pin),
             {:ok, payload} <- lower_payload(pin, note_id, derived) do
          {:cont, {:ok, put_pin(acc, pin.channel, note_id, payload)}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, by_channel} ->
          {:ok, Map.new([:pitch, :duration], &{&1, Map.get(by_channel, &1, %{})})}

        {:error, _} = error ->
          error
      end
    else
      :error -> {:error, {:unknown_track, track_id}}
    end
  end

  # snapshot 音符列表按时间升序派生组归属（与 mock/消费边界同一规则）。
  defp memberships(elements) do
    elements
    |> Enum.sort_by(fn {id, _note, {start_tick, _end_tick}} -> {start_tick, id} end)
    |> Enum.map(fn {id, note, {start_tick, end_tick}} ->
      {id, start_tick, end_tick, Syllable.flagged?(note.metadata)}
    end)
    |> Ref.memberships()
  end

  defp note_id(%Resolved{anchor: %Tamale.Anchor.Ordinal{refs: [note_id | _]}}),
    do: {:ok, note_id}

  defp note_id(%Resolved{anchor: other}), do: {:error, {:unsupported_anchor, other}}

  # legacy payload 原样透传（消费边界已理解这些形状）。
  defp lower_payload(
         %Resolved{descriptor: %Descriptor{payload_schema: schema}, payload: payload},
         _note_id,
         _derived
       )
       when schema in ["pitch_points_v1", "pitch_curve_v1", "phoneme_duration_v1"],
       do: {:ok, payload}

  # v2 note_tick → 绝对 tick 点列；偏移逐点保持原值（含越界/负值），
  # span 合法性由消费边界按 legacy 同一规则 loud 报错。
  defp lower_payload(
         %Resolved{descriptor: %Descriptor{payload_schema: @score_pitch_v2}, payload: payload},
         note_id,
         derived
       ) do
    with {:ok, {start_tick, _end_tick}} <- fetch_span(derived.spans, note_id),
         {:ok, values} <- fetch_values(payload) do
      {:ok, Enum.map(values, fn [offset, midi] -> [start_tick + offset, midi] end)}
    end
  end

  # v2 duration：segment ref → 成员自身序列内下标（legacy 同形）。ref 的
  # unit/member 与锚定音符的当前 membership 不一致即 loud 报错；index
  # 界内由消费边界复核（lowering 不做 probe，不知道序列长度）。
  defp lower_payload(
         %Resolved{
           descriptor: %Descriptor{payload_schema: @phoneme_duration_v2},
           payload: %{values: values}
         },
         note_id,
         derived
       )
       when is_list(values) do
    with {:ok, membership} <- fetch_membership(derived.memberships, note_id) do
      values
      |> Enum.reduce_while({:ok, []}, fn
        %{segment: %{unit: unit, member: member, index: index}, duration_tick: ticks}, {:ok, acc}
        when is_integer(member) and member >= 0 and is_integer(index) and index >= 0 and
               is_integer(ticks) and ticks > 0 ->
          if unit == membership.head_id and member == membership.member_index do
            {:cont, {:ok, [[index, ticks] | acc]}}
          else
            ref = %{unit: unit, member: member, index: index}
            {:halt, {:error, {:segment_ref_mismatch, note_id, ref}}}
          end

        other, {:ok, _acc} ->
          {:halt, {:error, {:invalid_phoneme_duration_v2_value, other}}}
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, _} = error -> error
      end
    end
  end

  defp lower_payload(
         %Resolved{descriptor: %Descriptor{payload_schema: schema}},
         _note_id,
         _derived
       ),
       do: {:error, {:unsupported_pin_schema, schema}}

  defp fetch_membership(memberships, note_id) do
    case Map.fetch(memberships, note_id) do
      {:ok, membership} -> {:ok, membership}
      :error -> {:error, {:unknown_note, note_id}}
    end
  end

  defp fetch_span(spans, note_id) do
    case Map.fetch(spans, note_id) do
      {:ok, span} -> {:ok, span}
      :error -> {:error, {:unknown_note, note_id}}
    end
  end

  defp fetch_values(%{schema: @score_pitch_v2, values: values}) do
    Enum.reduce_while(values, {:ok, []}, fn
      [offset, midi], {:ok, acc} when is_integer(offset) and is_number(midi) ->
        {:cont, {:ok, [[offset, midi * 1.0] | acc]}}

      other, {:ok, _acc} ->
        {:halt, {:error, {:invalid_score_pitch_v2_value, other}}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _} = error -> error
    end
  end

  defp fetch_values(other), do: {:error, {:invalid_score_pitch_v2, other}}

  defp put_pin(by_channel, channel, note_id, payload) do
    Map.update(by_channel, channel, %{note_id => payload}, &Map.put(&1, note_id, payload))
  end
end
