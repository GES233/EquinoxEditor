defmodule EquinoxDomain.Command.AdoptRequestTest do
  use ExUnit.Case, async: true

  import EquinoxDomain.TestFactory

  alias Coconut.Edit.{History, Workspace}
  alias Coconut.Edit.Operations.EditNote
  alias EquinoxDomain.Command.AdoptRequest
  alias EquinoxDomain.Port.Channels.PhonemeTiming

  @payload %{deltas: [%{identity: "ph_1", onset_delta_ms: 12, duration_delta_ms: -30}]}

  defp setup do
    {project, track_id} = project_with_track()
    project = insert_notes(project, track_id, [{"n1", 0, 480, %{pitch: 60, lyric: "あ"}}])
    {project, track_id}
  end

  test "build_patch：Ordinal 锚 + channel 投影算 base_digest" do
    {project, track_id} = setup()

    assert {:ok, patch} =
             AdoptRequest.build_patch(project.workspace, PhonemeTiming, %{
               track_id: track_id,
               anchor: {:ordinal, ["n1"]},
               payload: @payload
             })

    assert %Coconut.Edit.Patch{
             id: nil,
             track_id: ^track_id,
             channel: :phoneme_timing,
             anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], adjacent?: false},
             patch: %Tamale.Patch{base_digest: digest, payload: @payload}
           } = patch

    assert is_binary(digest)

    {:ok, track} = Coconut.Edit.Workspace.fetch_track(project.workspace, track_id)
    assert patch.anchor.at_version == track.space.version
  end

  test "build_patch：Relative 锚（offset 经 Coord 规整）" do
    {project, track_id} = setup()

    assert {:ok, patch} =
             AdoptRequest.build_patch(project.workspace, PhonemeTiming, %{
               track_id: track_id,
               anchor: {:relative, "n1", 0, 240},
               payload: @payload
             })

    # offset 经 Tamale.Coord.cast 规整为有理数 {n, d}
    assert %Tamale.Anchor.Relative{ref: "n1", from_offset: {0, 1}, to_offset: {240, 1}} =
             patch.anchor
  end

  test "build_patch 产出的 patch 可经 Workspace.attach_patch 挂载" do
    {project, track_id} = setup()

    {:ok, patch} =
      AdoptRequest.build_patch(project.workspace, PhonemeTiming, %{
        track_id: track_id,
        anchor: {:ordinal, ["n1"]},
        payload: @payload
      })

    assert {:ok, workspace, minted} = Workspace.attach_patch(project.workspace, patch)
    assert is_binary(minted.id)
    {:ok, track} = Workspace.fetch_track(workspace, track_id)
    assert [^minted] = track.patches
  end

  test "digest 语义：投影不变 resolve 成功；音符内容变化判 :base_changed" do
    {project, track_id} = setup()

    {:ok, patch} =
      AdoptRequest.build_patch(project.workspace, PhonemeTiming, %{
        track_id: track_id,
        anchor: {:ordinal, ["n1"]},
        payload: @payload
      })

    # 同一投影 → resolve 回 payload
    {:ok, base} = PhonemeTiming.projection(project.workspace, patch)
    assert {:ok, @payload} = Tamale.Patch.resolve(patch.patch, base)

    # 改歌词（经 History 写路径）→ base 变化 → 冲突
    hist = History.new(project.workspace)

    {:ok, hist} =
      History.apply(hist, %EditNote{track_id: track_id, note_id: "n1", changes: %{lyric: "い"}})

    {:ok, fresh_base} = PhonemeTiming.projection(hist.present, patch)
    assert {:conflict, :base_changed} = Tamale.Patch.resolve(patch.patch, fresh_base)
  end

  test "错误路径：缺字段 / 未知轨道 / 非法锚 / channel 不支持的锚" do
    {project, track_id} = setup()

    assert {:error, {:missing_adopt_attr, :payload}} =
             AdoptRequest.build_patch(project.workspace, PhonemeTiming, %{
               track_id: track_id,
               anchor: {:ordinal, ["n1"]}
             })

    assert {:error, {:unknown_track, "Track_x"}} =
             AdoptRequest.build_patch(project.workspace, PhonemeTiming, %{
               track_id: "Track_x",
               anchor: {:ordinal, ["n1"]},
               payload: @payload
             })

    assert {:error, {:invalid_anchor_spec, _}} =
             AdoptRequest.build_patch(project.workspace, PhonemeTiming, %{
               track_id: track_id,
               anchor: :bogus,
               payload: @payload
             })

    # PhonemeTiming 只吃 Ordinal / Relative；Metric 走 projection 报 :unsupported_anchor
    assert {:error, :unsupported_anchor} =
             AdoptRequest.build_patch(project.workspace, PhonemeTiming, %{
               track_id: track_id,
               anchor: %Tamale.Anchor.Metric{coord: :tick, from: 0, to: 480},
               payload: @payload
             })
  end
end
