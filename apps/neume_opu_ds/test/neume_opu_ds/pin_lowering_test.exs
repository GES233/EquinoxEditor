defmodule NeumeOpuDs.PinLoweringTest do
  @moduledoc """
  lowering 双 runtime 契约（`design-2026-09-pin-carriers` §10）：同一份
  `Neume.Pin.Resolved` 列表，mock 与 `NeumeOpuDs.Runtime` 的
  `lower_pins/4` 产出同一 pins map；不支持的 payload schema 两边都返回
  `{:unsupported_pin_schema, schema}` tagged error，不静默猜解。
  """

  use ExUnit.Case, async: true

  alias Neume.Pin.{Descriptor, Resolved, Schema}

  setup do
    {:ok, editor} =
      Neume.Editor.new(
        project_id: "project-lowering-contract",
        workspace_id: "workspace-lowering-contract",
        ticks_per_frame: 10
      )

    {:ok, editor} =
      Neume.Editor.insert_note(editor, "n1", :head, {240, 720}, %{pitch: 60, lyric: "la"})

    {:ok, request} = Coconut.request(editor.session)
    %{snapshot: request.snapshot, track_id: editor.track_id}
  end

  defp resolved(descriptor_schema, base_schema, carrier, note_id, payload) do
    %Resolved{
      channel: if(carrier == :score, do: :pitch, else: :duration),
      descriptor: %Descriptor{
        payload_schema: descriptor_schema,
        base_schema: base_schema,
        carrier: carrier
      },
      anchor: %Tamale.Anchor.Ordinal{refs: [note_id]},
      payload: payload
    }
  end

  test "同一 Resolved 批次两个 runtime lowering 结果一致", %{
    snapshot: snapshot,
    track_id: track_id
  } do
    resolved = [
      resolved(
        "score_pitch_v2",
        "score_region_v1",
        :score,
        "n1",
        Schema.score_pitch_v2_payload([[0, 61.0], [120, 72.0]])
      ),
      resolved("phoneme_duration_v1", "pin_input_v1", :correspondence, "n1", [[0, 96]]),
      resolved(
        "phoneme_duration_v2",
        "phoneme_correspondence_v1",
        :correspondence,
        "n1",
        Schema.phoneme_duration_v2_payload([
          %{segment: %{unit: "n1", member: 0, index: 1}, duration_tick: 48}
        ])
      )
    ]

    assert {:ok, pins} = NeumeOpuDs.Runtime.lower_pins(nil, snapshot, resolved, track_id)

    # note_tick 偏移按 snapshot 起点（240）平移为绝对 tick；legacy 透传；
    # v2 duration 的 segment ref 降为成员内下标（同 note/channel 后写
    # 覆盖，v2 条目覆盖同音符的 legacy 条目）。
    assert pins == %{
             pitch: %{"n1" => [[240, 61.0], [360, 72.0]]},
             duration: %{"n1" => [[1, 48]]}
           }

    assert {:ok, ^pins} =
             Neume.Engine.MockPipeline.lower_pins(nil, snapshot, resolved, track_id)
  end

  test "v2 duration 的 segment ref 失配，两个 runtime 同样 loud 报错", %{
    snapshot: snapshot,
    track_id: track_id
  } do
    resolved = [
      resolved(
        "phoneme_duration_v2",
        "phoneme_correspondence_v1",
        :correspondence,
        "n1",
        Schema.phoneme_duration_v2_payload([
          %{segment: %{unit: "n9", member: 0, index: 0}, duration_tick: 48}
        ])
      )
    ]

    expected = {:error, {:segment_ref_mismatch, "n1", %{unit: "n9", member: 0, index: 0}}}

    assert ^expected = NeumeOpuDs.Runtime.lower_pins(nil, snapshot, resolved, track_id)

    assert ^expected =
             Neume.Engine.MockPipeline.lower_pins(nil, snapshot, resolved, track_id)
  end

  test "不支持的 schema 两个 runtime 都返回 tagged error", %{
    snapshot: snapshot,
    track_id: track_id
  } do
    resolved = [resolved("score_pitch_v9", "score_region_v9", :score, "n1", %{})]

    assert {:error, {:unsupported_pin_schema, "score_pitch_v9"}} =
             NeumeOpuDs.Runtime.lower_pins(nil, snapshot, resolved, track_id)

    assert {:error, {:unsupported_pin_schema, "score_pitch_v9"}} =
             Neume.Engine.MockPipeline.lower_pins(nil, snapshot, resolved, track_id)
  end
end
