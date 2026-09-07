defmodule Neume.PinSemanticsTest do
  @moduledoc """
  pin carrier 协议骨架（`design-2026-09-pin-carriers` 批次 A）：Descriptor /
  Context / Semantics 按 payload 分派，legacy base 与 expressibility 行为
  与分派前完全一致。端到端语义（爆炸半径、repatch 降级）由
  `Neume.IdentityPinTest` 继续钉住。
  """

  use ExUnit.Case, async: true

  alias Coconut.Edit.History
  alias Neume.Channels.{DurationPin, PitchPin}
  alias Neume.{Editor, Identity}
  alias Neume.Pin.{Context, Descriptor, Semantics}

  # 只实现 Coconut transport、未实现 pin 语义回调的 channel（入口校验用）。
  defmodule BareChannel do
    @moduledoc false
    def resolve_stage, do: :probe
  end

  # 实现 Coconut transport 但不实现 pin 语义的 channel：能通过静态 check，
  # repatch 在语义入口校验处降级为 tagged error。
  defmodule TransportOnlyChannel do
    @moduledoc false
    def projection(_ws, _patch), do: {:error, :probe_stage_channel}

    def target(%Coconut.Edit.Patch{anchor: %Tamale.Anchor.Ordinal{refs: [id | _]}}),
      do: {:port, id, :duration}

    def resolve_stage, do: :probe
  end

  # 包装 mock 管线：phonemes/3 直接 raise，证明纯 Pin<S> 的 re-patch 不
  # 触碰音素展开（批次 A 评审：score pin 不应依赖 probe）。
  defmodule NoPhonemesPipeline do
    @moduledoc false
    alias Neume.Engine.MockPipeline

    defdelegate compile(opts), to: MockPipeline
    defdelegate voicebank_digest(state), to: MockPipeline
    defdelegate checked_pins(data), to: MockPipeline
    defdelegate engine_config(state, track_id), to: MockPipeline
    defdelegate base_data(snapshot, track_id), to: MockPipeline
    defdelegate analyze_phrases(state, snapshot, pins, globals, track_id), to: MockPipeline
    defdelegate analyze(state, snapshot, pins, globals, track_id), to: MockPipeline
    defdelegate render(state, snapshot, pins, globals, track_id), to: MockPipeline
    defdelegate fetch_artifact(result), to: MockPipeline

    def phonemes(_state, _snapshot, _track_id),
      do: raise("phonemes/3 不应在纯 Pin<S> re-patch 中被调用")
  end

  setup do
    {:ok, editor} =
      Editor.new(
        project_id: "project-pin-semantics",
        workspace_id: "workspace-pin-semantics",
        ticks_per_frame: 10
      )

    {:ok, editor} =
      Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    {:ok, editor: editor}
  end

  defp current_track(editor) do
    History.current(editor.session.history).workspace.tracks[editor.track_id]
  end

  defp context(editor, opts \\ []) do
    Context.new(current_track(editor), editor.track_id, nil, opts)
  end

  describe "describe/1 按 payload 分派 descriptor" do
    test "旧 pitch 点列是 Pin<S>，签 pin_input_v1" do
      assert {:ok,
              %Descriptor{
                payload_schema: "pitch_points_v1",
                base_schema: "pin_input_v1",
                carrier: :score
              }} = PitchPin.describe([[0, 60.0]])
    end

    test "pitch_curve_v1 Bezier plain map 是 Pin<S>，签 pin_input_v1" do
      payload = %{
        format: :pitch_curve_v1,
        adapter: :bezier,
        coord: :absolute_tick,
        value: :absolute_midi,
        points: []
      }

      assert {:ok,
              %Descriptor{
                payload_schema: "pitch_curve_v1",
                base_schema: "pin_input_v1",
                carrier: :score
              }} = PitchPin.describe(payload)
    end

    test "未知 pitch payload 返回 tagged error" do
      assert {:error, {:unknown_pitch_payload_schema, %{format: :nope}}} =
               PitchPin.describe(%{format: :nope})
    end

    test "旧 duration 点列是 Pin<Co<S,Ph>>，签 pin_input_v1" do
      assert {:ok,
              %Descriptor{
                payload_schema: "phoneme_duration_v1",
                base_schema: "pin_input_v1",
                carrier: :correspondence
              }} = DurationPin.describe([[0, 96]])
    end

    test "未知 duration payload 返回 tagged error" do
      assert {:error, {:unknown_duration_payload_schema, "x"}} = DurationPin.describe("x")
    end
  end

  describe "base/4（legacy 委托）" do
    test "两个 channel 的底料与 Identity.base_for/3 完全一致", %{editor: editor} do
      {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[0, 96]])
      patch = hd(current_track(editor).patches)
      {:ok, descriptor} = DurationPin.describe(patch.patch.payload)

      assert {:ok, expected} = Identity.base_for(current_track(editor), "n1", nil)
      assert {:ok, ^expected} = DurationPin.base(context(editor), patch.anchor, descriptor, nil)
      assert {:ok, ^expected} = PitchPin.base(context(editor), patch.anchor, descriptor, nil)
    end

    test "非存活音符与不支持 anchor 的 error 形状不变", %{editor: editor} do
      anchor = %Tamale.Anchor.Ordinal{refs: ["n9"]}

      assert {:error, {:unknown_note, "n9"}} =
               DurationPin.base(context(editor), anchor, nil, nil)

      assert {:error, {:unsupported_anchor, %Tamale.Anchor.Metric{}}} =
               PitchPin.base(context(editor), %Tamale.Anchor.Metric{}, nil, nil)
    end
  end

  describe "expressible?/4" do
    test "duration 下标在 probe 序列界内则 :ok，越界原因形状不变", %{editor: editor} do
      anchor = %Tamale.Anchor.Ordinal{refs: ["n1"]}
      probe = %{"n1" => [["zh", "l"], ["zh", "a"]]}
      context = context(editor, legacy_probe: probe)

      assert :ok = DurationPin.expressible?(context, anchor, nil, [[1, 96]])

      assert {:error, {:phoneme_index_out_of_range, 2, 2}} =
               DurationPin.expressible?(context, anchor, nil, [[2, 96]])

      assert {:error, {:invalid_duration_payload, "x"}} =
               DurationPin.expressible?(context, anchor, nil, ["x"])
    end

    test "duration 缺 probe 序列时按 unknown_note 拒绝", %{editor: editor} do
      anchor = %Tamale.Anchor.Ordinal{refs: ["n1"]}

      assert {:error, {:unknown_note, "n1"}} =
               DurationPin.expressible?(context(editor), anchor, nil, [[0, 96]])
    end

    test "pitch 恒可表达，不读 legacy_probe", %{editor: editor} do
      assert :ok = PitchPin.expressible?(context(editor), %Tamale.Anchor.Ordinal{}, nil, [])
    end
  end

  describe "Identity.adjudicate/3 分派" do
    test "经 channel semantics 分派，冲突 entry 形状不变", %{editor: editor} do
      {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[0, 96]])
      {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lu"})

      assert [
               %{
                 kind: :conflict,
                 stage: :probe,
                 channel: :duration,
                 patch: %Coconut.Edit.Patch{},
                 reason: :base_changed
               }
             ] = Identity.adjudicate(current_track(editor), editor.session.channels, nil)
    end

    test "describe 失败的 payload 在同一冲突界面聚合", %{editor: editor} do
      {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[0, 96]])
      track = current_track(editor)
      [patch] = track.patches
      broken = put_in(patch.patch.payload, "not-a-list")
      track = %{track | patches: [broken]}

      assert [%{kind: :conflict, stage: :probe, reason: {:unknown_duration_payload_schema, _}}] =
               Identity.adjudicate(track, editor.session.channels, nil)
    end

    test "channel 未实现 pin 语义回调时聚合 tagged error，不抛异常", %{editor: editor} do
      {:ok, editor} = Editor.mount_pitch(editor, "n1", [[0, 60.0]])
      track = current_track(editor)

      assert [
               %{
                 kind: :conflict,
                 stage: :probe,
                 reason: {:missing_pin_semantics, BareChannel}
               }
             ] = Identity.adjudicate(track, %{pitch: BareChannel}, nil)
    end

    test "整轨底料预计算进 Context.legacy_bases，逐 patch 复用", %{editor: editor} do
      {:ok, editor} = Editor.mount_pitch(editor, "n1", [[0, 60.0]])
      {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[0, 96]])
      track = current_track(editor)

      bases = Identity.base_by_note(track, nil)
      context = Context.new(track, editor.track_id, nil, legacy_bases: bases)
      [patch | _] = track.patches
      {:ok, descriptor} = DurationPin.describe([[0, 96]])

      assert {:ok, expected} = Identity.base_for(track, "n1", nil)

      assert {:ok, ^expected} =
               DurationPin.base(context, patch.anchor, descriptor, patch.patch.payload)

      # 预计算底料覆盖时，音符不在册也按 unknown_note 拒绝（行为不变）。
      assert {:error, {:unknown_note, "n9"}} =
               DurationPin.base(context, %Tamale.Anchor.Ordinal{refs: ["n9"]}, descriptor, nil)
    end
  end

  describe "Semantics 入口校验与 probe 需求" do
    test "implemented?/1 识别完整与不完整的语义实现" do
      assert Semantics.implemented?(PitchPin)
      assert Semantics.implemented?(DurationPin)
      refute Semantics.implemented?(BareChannel)
    end

    test "requires_probe?/2 按 carrier 分派：duration 需要，pitch 不需要" do
      {:ok, co} = DurationPin.describe([[0, 96]])
      {:ok, s} = PitchPin.describe([[0, 60.0]])

      assert DurationPin.requires_probe?(co, [[0, 96]])
      refute PitchPin.requires_probe?(s, [[0, 60.0]])
    end

    test "纯 pitch pin 的 repatch 不调用 pipeline.phonemes/3", %{editor: editor} do
      # legacy pitch 点列（签 pin_input_v1）：改词才会炸；v2 改词不炸，
      # 无从产生冲突 entry。NoPhonemesPipeline 不实现 lower_pins/4，同时
      # 覆盖纯 legacy 批次的 checked_pins/1 回退路径。
      {:ok, base} = Editor.probe_base(editor, "n1")

      {:ok, session, _patch} =
        Coconut.mount(editor.session, editor.track_id, "n1", :pitch, [[0, 60.0]], base: base)

      editor = %{editor | session: session}
      {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lu"})
      editor = %{editor | pipeline: NoPhonemesPipeline}

      assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe} = entry]}} =
               Editor.check(editor)

      assert {:ok, _editor, [%{status: :repatched}]} = Editor.repatch(editor, [entry])
    end

    test "duration pin 的 repatch 仍走 probe 序列校验", %{editor: editor} do
      {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[0, 96]])
      {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lu"})

      assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe} = entry]}} =
               Editor.check(editor)

      assert {:ok, _editor, [%{status: :repatched}]} = Editor.repatch(editor, [entry])
    end

    test "repatch 遇到未实现 pin 语义的 channel 时降级为 tagged error", %{editor: editor} do
      {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[0, 96]])
      [patch] = current_track(editor).patches
      session = editor.session
      channels = %{session.channels | duration: TransportOnlyChannel}
      editor = %{editor | session: %{session | channels: channels}}

      assert {:ok, _editor,
              [%{status: :degraded, reason: {:missing_pin_semantics, TransportOnlyChannel}}]} =
               Editor.repatch(editor, [patch.id])
    end
  end
end
