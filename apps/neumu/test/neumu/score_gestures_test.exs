defmodule Neumu.ScoreGesturesTest do
  @moduledoc """
  第三批手势的 facade 矩阵：`trim_note`、`merge_notes`（moved_pins
  报告）、`drag_note_across_tracks`（内容复制、清 melisma、pin 不迁移）。
  probe 走 `Neumu.ProjectStub.PhonemesClient`。
  """

  use ExUnit.Case, async: false

  @moduletag tmp_dir: true

  alias Neumu.ProjectStub
  alias Neumu.ProjectStub.PhonemesClient

  # 默认工程："lead" 与 "harmony" 两条 fixture 声库人声轨
  # （pin 0 = 空工程，pin 1 = lead，pin 2 = harmony）。
  setup %{tmp_dir: tmp_dir} do
    {registry, stock} = ProjectStub.stock_registry(tmp_dir)
    project_id = "project-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Neumu.create_project(project_id, ProjectStub.open_opts(registry, tmp_dir, PhonemesClient))

    {:ok, 1} = Neumu.add_track(project_id, "lead", stock.id)
    {:ok, 2} = Neumu.add_track(project_id, "harmony", stock.id)

    on_exit(fn ->
      if Neumu.ProjectServer.whereis(project_id), do: Neumu.close_project(project_id)
    end)

    %{project_id: project_id}
  end

  defp track(snapshot, track_id), do: Enum.find(snapshot.tracks, &(&1.id == track_id))

  defp notes!(project_id, track_id),
    do: project_id |> snapshot!() |> track(track_id) |> Map.fetch!(:notes)

  defp pins!(project_id, track_id),
    do: project_id |> snapshot!() |> track(track_id) |> Map.fetch!(:pins)

  defp snapshot!(project_id) do
    {:ok, snapshot} = Neumu.snapshot(project_id)
    snapshot
  end

  defp insert_note(project_id, track_id, note_id, after_id, span, lyric) do
    Neumu.insert_note(project_id, track_id, note_id, after_id, span, %{
      pitch: 60,
      lyric: lyric,
      phonemes: [["zh", "l"], ["zh", "a"]]
    })
  end

  test "trim_note 修剪时值落一条边，失败不改状态，可 undo/redo", %{project_id: id} do
    assert {:ok, 3} = insert_note(id, "lead", "n1", :head, {0, 480}, "la")
    assert {:ok, 4} = insert_note(id, "lead", "n2", "n1", {480, 960}, "mi")

    :ok = Neumu.subscribe(id)

    assert {:ok, 5} = Neumu.trim_note(id, "lead", "n1", {0, 240})
    assert_received {:project_changed, ^id, 5}
    assert [%{id: "n1", start_tick: 0, end_tick: 240}, %{id: "n2"}] = notes!(id, "lead")

    # 失败：压住邻居 / 未知音符 / 未知轨道，都不改状态、不发事件。
    assert {:error, {:vocal_overlap_rejected, _}} = Neumu.trim_note(id, "lead", "n1", {0, 600})
    assert {:error, {:unknown_note, "no-such"}} = Neumu.trim_note(id, "lead", "no-such", {0, 240})
    assert {:error, {:unknown_track, "no-such"}} = Neumu.trim_note(id, "no-such", "n1", {0, 240})
    assert {:ok, 5} = Neumu.history_pin(id)
    refute_received {:project_changed, _, _}

    assert {:ok, 4} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 4}
    assert [%{id: "n1", start_tick: 0, end_tick: 480} | _] = notes!(id, "lead")

    assert {:ok, 5} = Neumu.redo(id)
    assert_received {:project_changed, ^id, 5}
    assert [%{id: "n1", end_tick: 240} | _] = notes!(id, "lead")

    refute_received {:project_changed, _, _}
  end

  test "trim 拖出缝隙后 melisma 续音断组，probe 底料自动改派生", %{project_id: id} do
    assert {:ok, 3} = insert_note(id, "lead", "n1", :head, {0, 480}, "la")
    assert {:ok, 4} = Neumu.split_note(id, "lead", "n1", 240, "n1b")

    # 贴接：n1b 是 n1 的续音，底料 = 头的输入事实（continuation 形）。
    assert {:ok, %{base: %{group: group}}} = Neumu.probe_pin(id, "lead", "n1b")

    assert %{
             kind: "continuation",
             head: "n1",
             head_lyric: "la",
             head_phonemes: [["zh", "l"], ["zh", "a"]]
           } = group

    # 把 n1 剪短，拖出缝隙 → 旗标失效，n1b 按自身歌词/显式音素当头。
    assert {:ok, 5} = Neumu.trim_note(id, "lead", "n1", {0, 120})

    assert {:ok, %{base: %{group: %{kind: "head"}, lyric: "la"}}} =
             Neumu.probe_pin(id, "lead", "n1b")

    # 剪回去贴接，组关系恢复。
    assert {:ok, 6} = Neumu.trim_note(id, "lead", "n1", {0, 240})
    assert {:ok, %{base: %{group: %{kind: "continuation"}}}} = Neumu.probe_pin(id, "lead", "n1b")
  end

  test "merge_notes 合并相邻音符：into 留内容原样，可 undo/redo", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, 3} = insert_note(id, "lead", "n1", :head, {0, 480}, "la")
    assert {:ok, 4} = insert_note(id, "lead", "n2", "n1", {480, 960}, "mi")
    assert {:ok, 5} = insert_note(id, "lead", "n3", "n2", {960, 1440}, "lu")
    assert_received {:project_changed, ^id, 3}
    assert_received {:project_changed, ^id, 4}
    assert_received {:project_changed, ^id, 5}

    # 不相邻 / 未知音符 / 未知轨道：tagged error，不改状态、不发事件。
    assert {:error, {:ids_not_adjacent, ["n1", "n3"]}} =
             Neumu.merge_notes(id, "lead", ["n1", "n3"])

    assert {:error, {:unknown_id, "no-such"}} = Neumu.merge_notes(id, "lead", ["n1", "no-such"])
    assert {:error, {:unknown_track, "no-such"}} = Neumu.merge_notes(id, "no-such", ["n1", "n2"])
    assert {:ok, 5} = Neumu.history_pin(id)
    refute_received {:project_changed, _, _}

    assert {:ok, 6, %{moved_pins: []}} = Neumu.merge_notes(id, "lead", ["n1", "n2"])
    assert_received {:project_changed, ^id, 6}

    # into 保留自身内容原样（歌词不拼接），复合 span 覆盖两者。
    assert [%{id: "n1", start_tick: 0, end_tick: 960, lyric: "la", pitch: 60}, %{id: "n3"}] =
             notes!(id, "lead")

    # n1（复合）与 n3 现已相邻，可继续合并。
    assert {:ok, 7, %{moved_pins: []}} = Neumu.merge_notes(id, "lead", ["n1", "n3"])
    assert_received {:project_changed, ^id, 7}
    assert [%{id: "n1", start_tick: 0, end_tick: 1440}] = notes!(id, "lead")

    # undo 逐次还原被吸收者。
    assert {:ok, 6} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 6}
    assert [%{id: "n1", end_tick: 960}, %{id: "n3"}] = notes!(id, "lead")

    assert {:ok, 5} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 5}
    assert [%{id: "n1"}, %{id: "n2"}, %{id: "n3"}] = notes!(id, "lead")

    refute_received {:project_changed, _, _}
  end

  test "merge_notes 显式报告被吸收音符搬到 into 的 pin（moved_pins）", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, 3} = insert_note(id, "lead", "n1", :head, {0, 480}, "la")
    assert {:ok, 4} = insert_note(id, "lead", "n2", "n1", {480, 960}, "mi")
    assert_received {:project_changed, ^id, 3}
    assert_received {:project_changed, ^id, 4}

    # into（n1）与被吸收者（n2）各挂一个 pin。
    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n1")
    assert {:ok, 5} = Neumu.mount_pitch(id, "lead", "n1", [[120, 62]], probe)
    assert_received {:project_changed, ^id, 5}

    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n2")
    assert {:ok, 6} = Neumu.mount_phoneme_duration(id, "lead", "n2", [[0, 96]], probe)
    assert_received {:project_changed, ^id, 6}

    assert [%{id: n1_pin, channel: :pitch}, %{id: n2_pin, channel: :duration}] = pins!(id, "lead")

    # Tamale transport：被吸收音符的 ordinal 锚不死亡，重映射到 into。
    assert {:ok, 7, %{moved_pins: [moved]}} = Neumu.merge_notes(id, "lead", ["n1", "n2"])
    assert_received {:project_changed, ^id, 7}

    assert moved == %{id: n2_pin, channel: :duration, from_note_id: "n2", note_id: "n1"}

    # 快照：两个 pin 都在册、都锚在 n1 上；n2 消失。
    assert [
             %{id: ^n1_pin, channel: :pitch, anchor: %{refs: ["n1"]}},
             %{id: ^n2_pin, channel: :duration, anchor: %{refs: ["n1"]}}
           ] = pins!(id, "lead")

    assert [%{id: "n1", start_tick: 0, end_tick: 960}] = notes!(id, "lead")

    # undo 还原：n2 与其锚归位。
    assert {:ok, 6} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 6}

    assert [
             %{channel: :pitch, anchor: %{refs: ["n1"]}},
             %{channel: :duration, anchor: %{refs: ["n2"]}}
           ] = pins!(id, "lead")

    refute_received {:project_changed, _, _}
  end

  test "drag_note_across_tracks 复制内容、清 melisma、pin 不迁移", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, 3} = insert_note(id, "lead", "n1", :head, {0, 480}, "la")
    assert {:ok, 4} = Neumu.split_note(id, "lead", "n1", 240, "n1b")
    assert_received {:project_changed, ^id, 3}
    assert_received {:project_changed, ^id, 4}
    assert [%{id: "n1"}, %{id: "n1b", metadata: %{"melisma" => "continue"}}] = notes!(id, "lead")

    # 源音符上挂一个 pin：跨轨后不迁移（源轨 Delete 判死锚）。
    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n1b")
    assert {:ok, 5} = Neumu.mount_pitch(id, "lead", "n1b", [[300, 62]], probe)
    assert_received {:project_changed, ^id, 5}

    assert {:ok, 6} =
             Neumu.drag_note_across_tracks(id, "lead", "n1b", "harmony", "m1", :head, {0, 240})

    assert_received {:project_changed, ^id, 6}

    # 源轨：n1b 消失，其 pin 死进墓地（不随副本迁移）。
    assert [%{id: "n1"}] = notes!(id, "lead")
    assert [] = pins!(id, "lead")

    # 目标轨：内容全量复制（pitch/lyric/显式音素），melisma 旗标清除。
    assert [
             %{
               id: "m1",
               start_tick: 0,
               end_tick: 240,
               pitch: 60,
               lyric: "la",
               metadata: metadata
             }
           ] = notes!(id, "harmony")

    assert metadata["phonemes"] == [["zh", "l"], ["zh", "a"]]
    refute Map.has_key?(metadata, "melisma")
    assert [] = pins!(id, "harmony")

    # 失败：同轨 / 未知源音符 / 未知目标轨 / 目标位置重叠，不改状态。
    assert {:error, {:same_track, "lead"}} =
             Neumu.drag_note_across_tracks(id, "lead", "n1", "lead", "x", :head, {0, 240})

    assert {:error, {:unknown_note, "no-such"}} =
             Neumu.drag_note_across_tracks(id, "lead", "no-such", "harmony", "x", :head, {0, 240})

    assert {:error, {:unknown_track, "no-such"}} =
             Neumu.drag_note_across_tracks(id, "lead", "n1", "no-such", "x", :head, {0, 240})

    assert {:error, {:vocal_overlap_rejected, _}} =
             Neumu.drag_note_across_tracks(id, "lead", "n1", "harmony", "x", "m1", {0, 240})

    assert {:ok, 6} = Neumu.history_pin(id)
    refute_received {:project_changed, _, _}

    # undo：源音符连同 pin 一起回来，目标副本消失。
    assert {:ok, 5} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 5}
    assert [%{id: "n1"}, %{id: "n1b"}] = notes!(id, "lead")
    assert [%{channel: :pitch, anchor: %{refs: ["n1b"]}}] = pins!(id, "lead")
    assert [] = notes!(id, "harmony")

    assert {:ok, 6} = Neumu.redo(id)
    assert_received {:project_changed, ^id, 6}
    assert [%{id: "m1"}] = notes!(id, "harmony")

    refute_received {:project_changed, _, _}
  end
end
