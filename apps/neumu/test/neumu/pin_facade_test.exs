defmodule Neumu.PinFacadeTest do
  @moduledoc """
  pin 族手势的 facade 矩阵：两阶段挂载（probe 在 ProjectServer 外、mount
  携 pin 校验）、repatch 批量重挂、unmount_pin，以及快照 pins 投影。
  probe 走 `Neumu.ProjectStub.PhonemesClient`（纯 Elixir 假 G2P/组展开）。
  """

  use ExUnit.Case, async: false

  @moduletag tmp_dir: true

  alias Neumu.ProjectStub
  alias Neumu.ProjectStub.PhonemesClient

  # 默认工程：一条 fixture 声库的 "lead" 人声轨 + 一个双音素音符
  # （pin 0 = 空工程，pin 1 = 加轨，pin 2 = 插音符）。
  setup %{tmp_dir: tmp_dir} do
    {registry, stock} = ProjectStub.stock_registry(tmp_dir)
    project_id = "project-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Neumu.create_project(project_id, ProjectStub.open_opts(registry, tmp_dir, PhonemesClient))

    {:ok, 1} = Neumu.add_track(project_id, "lead", stock.id)

    {:ok, 2} =
      Neumu.insert_note(project_id, "lead", "n1", :head, {0, 480}, %{
        pitch: 60,
        lyric: "la",
        phonemes: [["zh", "l"], ["zh", "a"]]
      })

    on_exit(fn ->
      if Neumu.ProjectServer.whereis(project_id), do: Neumu.close_project(project_id)
    end)

    %{project_id: project_id, registry: registry, tmp_dir: tmp_dir}
  end

  defp track(snapshot, track_id), do: Enum.find(snapshot.tracks, &(&1.id == track_id))
  defp pins!(project_id), do: project_id |> snapshot!() |> track("lead") |> Map.fetch!(:pins)

  defp snapshot!(project_id) do
    {:ok, snapshot} = Neumu.snapshot(project_id)
    snapshot
  end

  # 递归断言投影/令牌只含 plain data：无 PID/函数/引用/端口，无遗留 struct。
  defp assert_plain_data(term) do
    refute is_pid(term) or is_function(term) or is_reference(term) or is_port(term),
           "泄露运行时对象：#{inspect(term)}"

    cond do
      is_struct(term) -> flunk("泄露 struct：#{inspect(term)}")
      is_map(term) -> Enum.each(term, fn {k, v} -> assert_plain_data({k, v}) end)
      is_tuple(term) -> term |> Tuple.to_list() |> Enum.each(&assert_plain_data/1)
      is_list(term) -> Enum.each(term, &assert_plain_data/1)
      true -> :ok
    end
  end

  test "probe_pin 返回 plain-data 令牌，不改状态不发事件", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n1")

    assert probe == %{
             track_id: "lead",
             note_id: "n1",
             pin: 2,
             base: [["zh", "l"], ["zh", "a"]]
           }

    assert_plain_data(probe)

    # probe 是只读旁路：pin 不变、无事件。
    assert {:ok, 2} = Neumu.history_pin(id)
    assert {:error, {:unknown_note, "no-such"}} = Neumu.probe_pin(id, "lead", "no-such")
    assert {:error, {:unknown_track, "no-such"}} = Neumu.probe_pin(id, "no-such", "n1")
    refute_received {:project_changed, _, _}
  end

  test "mount_pitch 携 probe 落边，快照 pins 投影一致且无运行时对象", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n1")

    assert {:ok, 3} = Neumu.mount_pitch(id, "lead", "n1", [[120, 72]], probe)
    assert_received {:project_changed, ^id, 3}

    assert [
             %{
               id: patch_id,
               channel: :pitch,
               anchor: %{type: :ordinal, refs: ["n1"], at_version: _},
               payload: [[120, 72.0]]
             }
           ] = pins!(id)

    assert is_binary(patch_id)
    assert_plain_data(snapshot!(id))
    refute_received {:project_changed, _, _}
  end

  test "probe 期间工程被编辑，mount 以 stale_pin 拒绝且状态不变", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n1")

    # probe 之后工程前进了一条边。
    assert {:ok, 3} = Neumu.edit_note(id, "lead", "n1", %{pitch: 62})
    assert_received {:project_changed, ^id, 3}

    assert {:error, {:stale_pin, _}} =
             Neumu.mount_pitch(id, "lead", "n1", [[120, 72]], probe)

    # 状态不变、不发事件；重新 probe 后重试成功。
    assert {:ok, 3} = Neumu.history_pin(id)
    assert [] = pins!(id)
    refute_received {:project_changed, _, _}

    assert {:ok, fresh} = Neumu.probe_pin(id, "lead", "n1")
    assert fresh.pin == 3
    assert {:ok, 4} = Neumu.mount_pitch(id, "lead", "n1", [[120, 72]], fresh)
    assert_received {:project_changed, ^id, 4}
  end

  test "probe 令牌绑定 track/note，张冠李戴或畸形令牌被拒绝", %{project_id: id} do
    assert {:ok, 3} =
             Neumu.insert_note(id, "lead", "n2", "n1", {480, 960}, %{pitch: 62, lyric: "mi"})

    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n1")

    assert {:error, {:invalid_pin_probe, "lead", "n2", _}} =
             Neumu.mount_pitch(id, "lead", "n2", [[120, 72]], probe)

    assert {:error, {:invalid_pin_probe, "lead", "n1", _}} =
             Neumu.mount_pitch(id, "lead", "n1", [[120, 72]], %{})

    assert {:ok, 3} = Neumu.history_pin(id)
    assert [] = pins!(id)
  end

  test "mount_phoneme_duration 与 unmount_pin 闭环，可 undo/redo", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n1")

    assert {:ok, 3} = Neumu.mount_phoneme_duration(id, "lead", "n1", [[0, 96]], probe)
    assert_received {:project_changed, ^id, 3}
    assert [%{channel: :duration, payload: [[0, 96]]}] = pins!(id)

    assert {:ok, 4} = Neumu.unmount_pin(id, "lead", "n1", :duration)
    assert_received {:project_changed, ^id, 4}
    assert [] = pins!(id)

    # 无存活 pin：tagged error，不改状态。
    assert {:error, {:pin_not_found, "n1", :duration}} =
             Neumu.unmount_pin(id, "lead", "n1", :duration)

    assert {:error, {:pin_not_found, "n1", :pitch}} = Neumu.unmount_pin(id, "lead", "n1", :pitch)
    assert {:ok, 4} = Neumu.history_pin(id)

    # undo 恢复 pin，redo 再卸载。
    assert {:ok, 3} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 3}
    assert [%{channel: :duration}] = pins!(id)

    assert {:ok, 4} = Neumu.redo(id)
    assert_received {:project_changed, ^id, 4}
    assert [] = pins!(id)

    refute_received {:project_changed, _, _}
  end

  test "mount_pitch_curve 接受 plain-map payload 并原样投影", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n1")

    curve = %{
      format: :pitch_curve_v1,
      adapter: :bezier,
      coord: :absolute_tick,
      value: :absolute_midi,
      points: [
        %{tick: 0, value: 60, handle_left: nil, handle_right: %{tick: 120, value: 1.5}},
        %{tick: 479, value: 62, handle_left: %{tick: -120, value: -1.5}, handle_right: nil}
      ]
    }

    assert {:ok, 3} = Neumu.mount_pitch_curve(id, "lead", "n1", curve, probe)
    assert_received {:project_changed, ^id, 3}

    assert [%{channel: :pitch, payload: payload}] = pins!(id)

    assert payload == %{
             format: :pitch_curve_v1,
             adapter: :bezier,
             coord: :absolute_tick,
             value: :absolute_midi,
             points: [
               %{tick: 0, value: 60.0, handle_left: nil, handle_right: %{tick: 120, value: 1.5}},
               %{
                 tick: 479,
                 value: 62.0,
                 handle_left: %{tick: -120, value: -1.5},
                 handle_right: nil
               }
             ]
           }

    assert_plain_data(snapshot!(id))

    # 畸形 payload：tagged error，不落边。
    assert {:error, _} = Neumu.mount_pitch_curve(id, "lead", "n1", %{bogus: true}, probe)
    assert {:ok, 3} = Neumu.history_pin(id)
    refute_received {:project_changed, _, _}
  end

  test "repatch 批量重签返回 {:ok, pin, results}，一条历史边", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n1")
    assert {:ok, 3} = Neumu.mount_phoneme_duration(id, "lead", "n1", [[0, 96]], probe)
    assert_received {:project_changed, ^id, 3}
    assert [%{id: patch_id}] = pins!(id)

    # 改词换音素序列 → pin 失配（在册但底座过期），按 id 重签。
    assert {:ok, 4} = Neumu.edit_note(id, "lead", "n1", %{phonemes: [["zh", "l"], ["zh", "u"]]})
    assert_received {:project_changed, ^id, 4}

    assert {:ok, 5, [%{patch_id: ^patch_id, status: :repatched}]} =
             Neumu.repatch(id, "lead", [patch_id])

    assert_received {:project_changed, ^id, 5}
    assert [%{id: new_patch_id, channel: :duration, payload: [[0, 96]]}] = pins!(id)
    assert new_patch_id != patch_id

    # undo 一次整批还原（旧 pin 回来）。
    assert {:ok, 4} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 4}
    assert [%{id: ^patch_id}] = pins!(id)

    refute_received {:project_changed, _, _}
  end

  test "repatch 降级不落边不发事件；不在册的 patch 报 tagged error", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n1")

    # 下标 1 指向第二个音素。
    assert {:ok, 3} = Neumu.mount_phoneme_duration(id, "lead", "n1", [[1, 96]], probe)
    assert_received {:project_changed, ^id, 3}
    assert [%{id: patch_id}] = pins!(id)

    # 改成单音素词 → 下标 1 越界，repatch 降级。
    assert {:ok, 4} = Neumu.edit_note(id, "lead", "n1", %{phonemes: [["zh", "o"]]})
    assert_received {:project_changed, ^id, 4}

    assert {:ok, 4, [%{patch_id: ^patch_id, status: :degraded, reason: reason}]} =
             Neumu.repatch(id, "lead", [patch_id])

    assert reason == {:phoneme_index_out_of_range, 1, 1}

    # 全部降级：无新历史边、无事件，旧 patch 原样在册。
    assert {:ok, 4} = Neumu.history_pin(id)
    assert [%{id: ^patch_id}] = pins!(id)
    refute_received {:project_changed, _, _}

    assert {:error, {:patch_not_alive, "Patch_nope"}} = Neumu.repatch(id, "lead", ["Patch_nope"])
    assert {:error, {:unknown_track, "no-such"}} = Neumu.repatch(id, "no-such", [patch_id])
  end

  test "pin 随工程保存/重开恢复，undo 历史一并回来", %{
    project_id: id,
    registry: registry,
    tmp_dir: tmp_dir
  } do
    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n1")
    assert {:ok, 3} = Neumu.mount_pitch(id, "lead", "n1", [[120, 72]], probe)
    # 第一次 mount 后 pin 前进，旧 probe 作废，需重新 probe。
    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n1")
    assert {:ok, 4} = Neumu.mount_phoneme_duration(id, "lead", "n1", [[0, 96]], probe)

    assert [%{channel: :pitch}, %{channel: :duration}] = pins!(id)

    path = Path.join(tmp_dir, "pins.coconut")
    assert {:ok, ^path} = Neumu.save_project(id, path)
    assert :ok = Neumu.close_project(id)

    assert {:ok, _pid} =
             Neumu.load_project(
               id,
               path,
               ProjectStub.open_opts(registry, tmp_dir, PhonemesClient)
             )

    assert %{history_pin: 4} = snapshot!(id)

    assert [
             %{channel: :pitch, anchor: %{refs: ["n1"]}, payload: [[120, 72.0]]},
             %{channel: :duration, payload: [[0, 96]]}
           ] = pins!(id)

    # 存档 History 可继续 undo：duration pin 卸载边先还原。
    assert {:ok, 3} = Neumu.undo(id)
    assert [%{channel: :pitch}] = pins!(id)
    assert {:ok, 2} = Neumu.undo(id)
    assert [] = pins!(id)
  end
end
