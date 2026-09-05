defmodule Neumu.FacadeTest do
  use ExUnit.Case, async: false

  @moduletag tmp_dir: true

  alias Neumu.ProjectStub

  # 默认工程：一条 fixture 声库的 "lead" 人声轨（pin 0 = 空工程，pin 1 = 加轨）。
  setup %{tmp_dir: tmp_dir} do
    {registry, stock} = ProjectStub.stock_registry(tmp_dir)
    project_id = "project-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Neumu.create_project(project_id, ProjectStub.open_opts(registry, tmp_dir))
    {:ok, 1} = Neumu.add_track(project_id, "lead", stock.id)
    close_on_exit(project_id)

    %{
      project_id: project_id,
      registry: registry,
      stock: stock,
      tmp_dir: tmp_dir
    }
  end

  defp close_on_exit(project_id) do
    on_exit(fn ->
      if Neumu.ProjectServer.whereis(project_id), do: Neumu.close_project(project_id)
    end)
  end

  defp track(snapshot, track_id), do: Enum.find(snapshot.tracks, &(&1.id == track_id))

  # 阻塞式 renderer：报告自身 pid 并等待测试进程放行。
  defp blocking_renderer(test_pid) do
    fn _multi_track ->
      send(test_pid, {:render_started, self()})

      receive do
        :release_render -> {:ok, ProjectStub.mix_artifact()}
      end
    end
  end

  # 递归断言快照只含 plain data：无 PID/函数/引用/端口，也没有遗留 struct。
  defp assert_plain_data(term) do
    refute is_pid(term) or is_function(term) or is_reference(term) or is_port(term),
           "快照泄露运行时对象：#{inspect(term)}"

    cond do
      is_struct(term) -> flunk("快照泄露 struct：#{inspect(term)}")
      is_map(term) -> Enum.each(term, fn {k, v} -> assert_plain_data({k, v}) end)
      is_tuple(term) -> term |> Tuple.to_list() |> Enum.each(&assert_plain_data/1)
      is_list(term) -> Enum.each(term, &assert_plain_data/1)
      true -> :ok
    end
  end

  test "快照展示轨道、音符、mix/globals 与 History cursor，且不泄露运行时对象", %{
    project_id: id,
    stock: stock
  } do
    assert {:ok, snapshot} = Neumu.snapshot(id)
    assert snapshot.project_id == id
    assert snapshot.history_pin == 1
    assert {:ok, 1} = Neumu.history_pin(id)

    lead = track(snapshot, "lead")
    assert lead.name == nil
    assert lead.voicebank == stock.signature
    assert lead.mix == %{gain: 1.0, pan: 0.0, mute: false}
    assert lead.globals == %{}
    assert lead.notes == []

    assert {:ok, 2} =
             Neumu.insert_note(id, "lead", "n1", :head, {0, 480}, %{
               pitch: 60,
               lyric: "la",
               phonemes: [["l", "a"]]
             })

    assert {:ok, snapshot} = Neumu.snapshot(id)
    assert snapshot.history_pin == 2
    assert {:ok, 2} = Neumu.history_pin(id)

    assert [
             %{
               id: "n1",
               start_tick: 0,
               end_tick: 480,
               pitch: 60,
               lyric: "la",
               annotation: nil,
               metadata: %{"phonemes" => [["l", "a"]]}
             }
           ] = track(snapshot, "lead").notes

    assert_plain_data(snapshot)
  end

  test "查询不产生 History 边也不派发事件", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    assert {:ok, snapshot} = Neumu.snapshot(id)
    assert {:ok, ^snapshot} = Neumu.snapshot(id)
    assert {:ok, 1} = Neumu.history_pin(id)
    assert {:error, {:job_not_found, :none}} = Neumu.render_job(id, :none)

    assert {:ok, 1} = Neumu.history_pin(id)
    refute_received {:project_changed, _, _}
  end

  test "音符增删改移都落权威状态，成功编辑只发一次 project_changed", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    assert {:ok, 2} =
             Neumu.insert_note(id, "lead", "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert_received {:project_changed, ^id, 2}

    assert [%{id: "n1", start_tick: 0, end_tick: 480, pitch: 60, lyric: "la"}] =
             id |> snapshot!() |> track("lead") |> Map.fetch!(:notes)

    assert {:ok, 3} = Neumu.edit_note(id, "lead", "n1", %{lyric: "lu", pitch: 62})
    assert_received {:project_changed, ^id, 3}
    assert [%{id: "n1", lyric: "lu", pitch: 62}] = notes!(id)

    assert {:ok, 4} = Neumu.move_note(id, "lead", "n1", :head, {480, 960})
    assert_received {:project_changed, ^id, 4}
    assert [%{id: "n1", start_tick: 480, end_tick: 960}] = notes!(id)

    assert {:ok, 5} = Neumu.delete_note(id, "lead", "n1")
    assert_received {:project_changed, ^id, 5}
    assert [] = notes!(id)

    refute_received {:project_changed, _, _}
  end

  test "mix 与 globals 更新经同一 History，globals 无变化不落边不发事件", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    assert {:ok, 2} = Neumu.update_mix(id, "lead", %{gain: 0.5, pan: -1.0})
    assert_received {:project_changed, ^id, 2}
    assert track(snapshot!(id), "lead").mix == %{gain: 0.5, pan: -1.0, mute: false}

    assert {:ok, 3} = Neumu.update_globals(id, "lead", %{energy: 1.5})
    assert_received {:project_changed, ^id, 3}
    assert track(snapshot!(id), "lead").globals == %{energy: 1.5}

    # 相同写入无变化：返回当前 pin，不落历史边，不发事件。
    assert {:ok, 3} = Neumu.update_globals(id, "lead", %{energy: 1.5})
    refute_received {:project_changed, _, _}

    # nil 删除键，落一条新历史边。
    assert {:ok, 4} = Neumu.update_globals(id, "lead", %{energy: nil})
    assert_received {:project_changed, ^id, 4}
    assert track(snapshot!(id), "lead").globals == %{}
  end

  test "undo/redo 更新 pin、刷新快照并逐次派发事件", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, 2} = Neumu.insert_note(id, "lead", "n1", :head, {0, 480}, %{pitch: 60})
    assert_received {:project_changed, ^id, 2}

    assert {:ok, 1} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 1}
    assert [] = notes!(id)

    assert {:ok, 2} = Neumu.redo(id)
    assert_received {:project_changed, ^id, 2}
    assert [%{id: "n1"}] = notes!(id)

    assert {:error, :nothing_to_redo} = Neumu.redo(id)

    assert {:ok, 1} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 1}
    assert {:ok, 0} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 0}
    assert snapshot!(id).tracks == []

    assert {:error, :nothing_to_undo} = Neumu.undo(id)

    assert {:ok, 1} = Neumu.redo(id)
    assert_received {:project_changed, ^id, 1}
    assert [%{id: "lead"}] = snapshot!(id).tracks

    refute_received {:project_changed, _, _}
  end

  test "失败编辑不改状态、不发事件", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, 2} = Neumu.insert_note(id, "lead", "n1", :head, {0, 480}, %{pitch: 60})
    assert_received {:project_changed, ^id, 2}
    assert {:ok, before_snapshot} = Neumu.snapshot(id)

    failures = [
      Neumu.insert_note(id, "lead", "n2", :head, {240, 720}, %{pitch: 60}),
      Neumu.edit_note(id, "lead", "no-such-note", %{lyric: "x"}),
      Neumu.delete_note(id, "lead", "no-such-note"),
      Neumu.move_note(id, "lead", "n1", :head, {-480, 0}),
      Neumu.update_mix(id, "lead", %{gain: -1.0}),
      Neumu.update_mix(id, "no-such-track", %{gain: 1.0}),
      Neumu.update_globals(id, "no-such-track", %{energy: 1.0}),
      Neumu.add_track(id, "other", "no-such-voicebank"),
      Neumu.remove_track(id, "no-such-track"),
      Neumu.rebind_voicebank(id, "lead", "no-such-voicebank")
    ]

    assert Enum.all?(failures, &match?({:error, _}, &1)), inspect(failures)
    assert {:error, {:vocal_overlap_rejected, _}} = hd(failures)
    assert {:error, {:unknown_track, "no-such-track"}} = Enum.at(failures, 8)
    assert {:error, {:voicebank_not_registered, "no-such-voicebank"}} = Enum.at(failures, 9)

    # 状态与 pin 均未变化，且没有派发任何 project_changed。
    assert {:ok, 2} = Neumu.history_pin(id)
    assert {:ok, ^before_snapshot} = Neumu.snapshot(id)
    refute_received {:project_changed, _, _}
  end

  test "轨道增删与声库重绑定都经权威状态并可 undo", %{
    registry: registry,
    stock: stock,
    tmp_dir: tmp_dir
  } do
    modified = ProjectStub.modified_entry(stock, tmp_dir)
    registry = %{registry | entries: Map.put(registry.entries, modified.id, modified)}

    id = "project-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Neumu.create_project(id, ProjectStub.open_opts(registry, tmp_dir))
    close_on_exit(id)
    :ok = Neumu.subscribe(id)

    assert {:ok, 1} = Neumu.add_track(id, "lead", stock.id, %{name: "主唱", mix: %{gain: 0.8}})

    lead = track(snapshot!(id), "lead")
    assert lead.name == "主唱"
    assert lead.mix.gain == 0.8
    assert lead.voicebank == stock.signature

    assert {:ok, 2} = Neumu.rebind_voicebank(id, "lead", modified.id)
    assert_received {:project_changed, ^id, 2}
    assert track(snapshot!(id), "lead").voicebank == modified.signature

    assert {:ok, 1} = Neumu.undo(id)
    assert track(snapshot!(id), "lead").voicebank == stock.signature

    assert {:ok, 3} = Neumu.remove_track(id, "lead")
    assert_received {:project_changed, ^id, 3}
    assert snapshot!(id).tracks == []

    assert {:ok, 2} = Neumu.undo(id)
    assert [%{id: "lead"}] = snapshot!(id).tracks
  end

  test "保存后重新打开能恢复工程与 undo/redo History", %{
    project_id: id,
    registry: registry,
    tmp_dir: tmp_dir
  } do
    assert {:ok, 2} =
             Neumu.insert_note(id, "lead", "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, 3} = Neumu.update_mix(id, "lead", %{gain: 0.5})
    assert {:ok, 4} = Neumu.update_globals(id, "lead", %{breathiness: 1.2})

    :ok = Neumu.subscribe(id)
    path = Path.join(tmp_dir, "project.coconut")
    assert {:ok, ^path} = Neumu.save_project(id, path)
    # 保存不改状态、不发事件。
    assert {:ok, 4} = Neumu.history_pin(id)
    refute_received {:project_changed, _, _}

    assert :ok = Neumu.close_project(id)
    assert {:ok, _pid} = Neumu.load_project(id, path, ProjectStub.open_opts(registry, tmp_dir))

    assert {:ok, snapshot} = Neumu.snapshot(id)
    assert snapshot.history_pin == 4
    lead = track(snapshot, "lead")
    assert lead.mix == %{gain: 0.5, pan: 0.0, mute: false}
    assert lead.globals == %{breathiness: 1.2}
    assert [%{id: "n1", lyric: "la", start_tick: 0, end_tick: 480}] = lead.notes

    # 存档的 History 可继续 undo/redo。
    assert {:ok, 3} = Neumu.undo(id)
    assert track(snapshot!(id), "lead").globals == %{}
    assert {:ok, 2} = Neumu.undo(id)
    assert track(snapshot!(id), "lead").mix.gain == 1.0
    assert {:ok, 3} = Neumu.redo(id)
    assert track(snapshot!(id), "lead").mix.gain == 0.5
  end

  test "渲染钉住提交时版本，后续编辑不改变 job.source_pin", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, 1} = Neumu.history_pin(id)

    assert {:ok, job} = Neumu.submit_render(id, renderer: blocking_renderer(self()))
    assert job.source_pin == 1
    assert_received {:render_changed, job_id, :running}
    assert job_id == job.id
    assert_receive {:render_started, render_pid}

    assert {:ok, 2} = Neumu.insert_note(id, "lead", "n1", :head, {0, 480}, %{pitch: 60})
    assert_received {:project_changed, ^id, 2}

    assert {:ok, running} = Neumu.render_job(id, job.id)
    assert running.status == :running
    assert running.source_pin == 1

    send(render_pid, :release_render)
    assert_receive {:render_changed, ^job_id, :completed}
    assert_receive {:artifact_ready, ^job_id, _artifact_id, 1}

    assert {:ok, done} = Neumu.render_job(id, job.id)
    assert done.status == :completed
    assert done.source_pin == 1
  end

  test "并发编辑串行落账，不丢更新", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    count = 20

    results =
      1..count
      |> Enum.map(fn i ->
        Task.async(fn ->
          Neumu.insert_note(id, "lead", "n#{i}", :head, {i * 480, i * 480 + 240}, %{
            pitch: 60,
            lyric: "l#{i}"
          })
        end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    pins = Enum.map(results, fn {:ok, pin} -> pin end)
    assert Enum.sort(pins) == Enum.to_list(2..(count + 1))

    # 事件按落账顺序逐次到达，pin 严格递增且每个只出现一次。
    for pin <- 2..(count + 1) do
      assert_received {:project_changed, ^id, ^pin}
    end

    refute_received {:project_changed, _, _}

    assert {:ok, snapshot} = Neumu.snapshot(id)
    assert snapshot.history_pin == count + 1
    notes = track(snapshot, "lead").notes
    assert length(notes) == count
    assert Enum.map(notes, & &1.start_tick) == Enum.map(1..count, &(&1 * 480))
  end

  test "未知工程的所有 facade 入口返回 tagged error" do
    assert {:error, {:unknown_project, :nope}} = Neumu.snapshot(:nope)
    assert {:error, {:unknown_project, :nope}} = Neumu.save_project(:nope, "x.coconut")
    assert {:error, {:unknown_project, :nope}} = Neumu.undo(:nope)
    assert {:error, {:unknown_project, :nope}} = Neumu.redo(:nope)

    assert {:error, {:unknown_project, :nope}} =
             Neumu.insert_note(:nope, "t", "n", :head, {0, 1}, %{})

    assert {:error, {:unknown_project, :nope}} =
             Neumu.split_note(:nope, "t", "n", 240, "n2")

    assert {:error, {:unknown_project, :nope}} = Neumu.rename_track(:nope, "t", "x")
    assert {:error, {:unknown_project, :nope}} = Neumu.set_time_sigs(:nope, [{1, {4, 4}}])
    assert {:error, {:unknown_project, :nope}} = Neumu.update_mix(:nope, "t", %{gain: 1.0})
    assert {:error, {:unknown_project, :nope}} = Neumu.update_globals(:nope, "t", %{})
    assert {:error, {:unknown_project, :nope}} = Neumu.add_track(:nope, "t", "vb")
    assert {:error, {:unknown_project, :nope}} = Neumu.remove_track(:nope, "t")
    assert {:error, {:unknown_project, :nope}} = Neumu.rebind_voicebank(:nope, "t", "vb")
  end

  test "split_note 拆音：右子补 melisma 旗标，一条历史边，可 undo/redo", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    assert {:ok, 2} =
             Neumu.insert_note(id, "lead", "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert_received {:project_changed, ^id, 2}

    assert {:ok, 3} = Neumu.split_note(id, "lead", "n1", 240, "n1b")
    assert_received {:project_changed, ^id, 3}

    assert [
             %{id: "n1", start_tick: 0, end_tick: 240, metadata: meta_l},
             %{id: "n1b", start_tick: 240, end_tick: 480, metadata: meta_r}
           ] = notes!(id)

    assert meta_l == %{}
    assert meta_r == %{"melisma" => "continue"}

    # 拆分点落在界外 / 未知音符：tagged error，不改状态、不发事件。
    assert {:ok, before_snapshot} = Neumu.snapshot(id)
    assert {:error, _} = Neumu.split_note(id, "lead", "n1", 240, "again-outside")
    assert {:error, _} = Neumu.split_note(id, "lead", "no-such-note", 120, "n2")
    assert {:error, _} = Neumu.split_note(id, "no-such-track", "n1", 120, "n2")
    assert {:ok, 3} = Neumu.history_pin(id)
    assert {:ok, ^before_snapshot} = Neumu.snapshot(id)
    refute_received {:project_changed, _, _}

    # undo 一次整手势还原（右子消失），redo 恢复。
    assert {:ok, 2} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 2}
    assert [%{id: "n1", start_tick: 0, end_tick: 480}] = notes!(id)

    assert {:ok, 3} = Neumu.redo(id)
    assert_received {:project_changed, ^id, 3}
    assert [%{id: "n1"}, %{id: "n1b"}] = notes!(id)

    refute_received {:project_changed, _, _}
  end

  test "rename_track 重命名落历史边并可 undo/redo，未知轨道报错不改状态", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert track(snapshot!(id), "lead").name == nil

    assert {:ok, 2} = Neumu.rename_track(id, "lead", "主唱")
    assert_received {:project_changed, ^id, 2}
    assert track(snapshot!(id), "lead").name == "主唱"

    assert {:ok, 3} = Neumu.rename_track(id, "lead", nil)
    assert_received {:project_changed, ^id, 3}
    assert track(snapshot!(id), "lead").name == nil

    assert {:error, {:unknown_track, "no-such-track"}} =
             Neumu.rename_track(id, "no-such-track", "x")

    assert {:ok, 3} = Neumu.history_pin(id)

    assert {:ok, 2} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 2}
    assert track(snapshot!(id), "lead").name == "主唱"

    assert {:ok, 3} = Neumu.redo(id)
    assert_received {:project_changed, ^id, 3}
    assert track(snapshot!(id), "lead").name == nil

    refute_received {:project_changed, _, _}
  end

  test "set_time_sigs 替换拍号并进快照投影，非法输入不落边", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    # 默认 4/4 从小节 1 开始；快照投影为 JSON-safe 形态（tuple 降为 list）。
    assert snapshot!(id).time_sigs == [[1, [4, 4]]]

    assert {:ok, 2} = Neumu.set_time_sigs(id, [{1, {3, 4}}, {5, {6, 8}}])
    assert_received {:project_changed, ^id, 2}
    assert snapshot!(id).time_sigs == [[1, [3, 4]], [5, [6, 8]]]
    assert_plain_data(snapshot!(id))

    # compound 与散拍子的投影形态（atom 保留，JSON 中即字符串）。
    assert {:ok, 3} = Neumu.set_time_sigs(id, [{1, {:compound, [2, 3], 8}}, {5, :san}])
    assert_received {:project_changed, ^id, 3}
    assert snapshot!(id).time_sigs == [[1, [:compound, [2, 3], 8]], [5, :san]]

    assert {:error, {:invalid_time_sigs, [{2, {4, 4}}]}} = Neumu.set_time_sigs(id, [{2, {4, 4}}])
    assert {:error, {:invalid_time_sigs, _}} = Neumu.set_time_sigs(id, [{1, {4, 0}}])
    assert {:ok, 3} = Neumu.history_pin(id)

    assert {:ok, 2} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 2}
    assert snapshot!(id).time_sigs == [[1, [3, 4]], [5, [6, 8]]]

    assert {:ok, 3} = Neumu.redo(id)
    assert_received {:project_changed, ^id, 3}
    assert snapshot!(id).time_sigs == [[1, [:compound, [2, 3], 8]], [5, :san]]
    refute_received {:project_changed, _, _}
  end

  test "快照投影 can_undo/can_redo 跟随 History cursor", %{project_id: id} do
    assert %{history_pin: 1, can_undo: true, can_redo: false} = snapshot!(id)

    assert {:ok, 2} = Neumu.rename_track(id, "lead", "主唱")
    assert %{can_undo: true, can_redo: false} = snapshot!(id)

    assert {:ok, 1} = Neumu.undo(id)
    assert %{can_undo: true, can_redo: true} = snapshot!(id)

    assert {:ok, 0} = Neumu.undo(id)
    assert %{can_undo: false, can_redo: true} = snapshot!(id)

    assert {:ok, 1} = Neumu.redo(id)
    assert %{can_undo: true, can_redo: true} = snapshot!(id)

    assert {:ok, 2} = Neumu.redo(id)
    assert %{can_undo: true, can_redo: false} = snapshot!(id)
  end

  test "拆分、重命名与拍号在保存/重开后与 History 一并恢复", %{
    project_id: id,
    registry: registry,
    tmp_dir: tmp_dir
  } do
    assert {:ok, 2} = Neumu.set_time_sigs(id, [{1, {3, 4}}])
    assert {:ok, 3} = Neumu.rename_track(id, "lead", "主唱")

    assert {:ok, 4} =
             Neumu.insert_note(id, "lead", "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, 5} = Neumu.split_note(id, "lead", "n1", 240, "n1b")

    path = Path.join(tmp_dir, "gestures.coconut")
    assert {:ok, ^path} = Neumu.save_project(id, path)
    assert :ok = Neumu.close_project(id)
    assert {:ok, _pid} = Neumu.load_project(id, path, ProjectStub.open_opts(registry, tmp_dir))

    snapshot = snapshot!(id)
    assert snapshot.history_pin == 5
    assert snapshot.time_sigs == [[1, [3, 4]]]
    lead = track(snapshot, "lead")
    assert lead.name == "主唱"

    assert [%{id: "n1", end_tick: 240}, %{id: "n1b", metadata: %{"melisma" => "continue"}}] =
             lead.notes

    # 存档 History 可继续 undo：拆分整手势一次还原。
    assert {:ok, 4} = Neumu.undo(id)
    assert [%{id: "n1", start_tick: 0, end_tick: 480}] = notes!(id)
    assert {:ok, 3} = Neumu.undo(id)
    assert [] = notes!(id)
    assert {:ok, 2} = Neumu.undo(id)
    assert track(snapshot!(id), "lead").name == nil
  end

  test "create/load_project 拒绝 nil project_id", %{tmp_dir: tmp_dir} do
    assert {:error, {:invalid_project_id, nil}} = Neumu.create_project(nil)
    assert {:error, {:invalid_project_id, nil}} = Neumu.load_project(nil, Path.join(tmp_dir, "x"))
  end

  defp snapshot!(project_id) do
    {:ok, snapshot} = Neumu.snapshot(project_id)
    snapshot
  end

  defp notes!(project_id) do
    project_id |> snapshot!() |> track("lead") |> Map.fetch!(:notes)
  end
end
