defmodule Neumu.TempoFacadeTest do
  @moduledoc """
  tempo 台阶手势与时长查询的 facade 矩阵（手势计划第四批）：插/改/删、
  快照投影、undo/redo、保存重开、同 tick 拒绝、首事件保护、非法输入
  tagged error、查询只读无副作用、事件纪律（成功一次、失败不发）。
  """

  use ExUnit.Case, async: false

  @moduletag tmp_dir: true

  alias Neumu.ProjectStub
  alias Neumu.ProjectStub.PhonemesClient

  setup %{tmp_dir: tmp_dir} do
    {registry, stock} = ProjectStub.stock_registry(tmp_dir)
    project_id = "project-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Neumu.create_project(project_id, ProjectStub.open_opts(registry, tmp_dir, PhonemesClient))

    {:ok, 1} = Neumu.add_track(project_id, "lead", stock.id)

    on_exit(fn ->
      if Neumu.ProjectServer.whereis(project_id), do: Neumu.close_project(project_id)
    end)

    %{project_id: project_id}
  end

  defp steps(id) do
    {:ok, snapshot} = Neumu.snapshot(id)
    Enum.map(snapshot.tempo_steps, &{&1.id, &1.tick, &1.milli_bpm})
  end

  test "空轨：投影为空，时长查询回退 flat 120 BPM（引擎同款），只读无副作用", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    assert steps(id) == []
    # 960 tick = 2 拍；120 BPM → 1.0s
    assert {:ok, 1.0} = Neumu.region_duration_sec(id, 0, 960)

    assert {:ok, 1} = Neumu.history_pin(id)
    refute_received {:project_changed, _, _}
  end

  test "插台阶：投影 tick 升序、milli-bpm 精确整数，时长分段换算", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    # 乱序插入，投影仍按 tick 升序
    assert {:ok, 2} = Neumu.insert_tempo_step(id, "t1", 960, 120)
    assert_received {:project_changed, ^id, 2}
    assert {:ok, 3} = Neumu.insert_tempo_step(id, "t0", 0, 60)
    assert_received {:project_changed, ^id, 3}

    assert [{"t0", 0, 60_000}, {"t1", 960, 120_000}] = steps(id)

    assert {:ok, 2.0} = Neumu.region_duration_sec(id, 0, 960)
    assert {:ok, 1.0} = Neumu.region_duration_sec(id, 960, 1920)
    # 跨台阶区间：960@60 + 480@120 = 2.0 + 0.5
    assert {:ok, 2.5} = Neumu.region_duration_sec(id, 0, 1440)
  end

  test "改 bpm 与删台阶；undo/redo 还原", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    assert {:ok, _} = Neumu.insert_tempo_step(id, "t0", 0, 60)
    assert {:ok, _} = Neumu.insert_tempo_step(id, "t1", 960, 120)

    assert {:ok, _} = Neumu.edit_tempo_step(id, "t1", 90)
    assert [{"t0", 0, 60_000}, {"t1", 960, 90_000}] = steps(id)

    assert {:ok, _} = Neumu.delete_tempo_step(id, "t1")
    assert [{"t0", 0, 60_000}] = steps(id)

    assert {:ok, _} = Neumu.undo(id)
    assert [{"t0", 0, 60_000}, {"t1", 960, 90_000}] = steps(id)

    assert {:ok, _} = Neumu.redo(id)
    assert [{"t0", 0, 60_000}] = steps(id)
  end

  test "非法输入 tagged error：同 tick 拒绝、非法 bpm、非法 tick、首事件保护，均不落边不发事件",
       %{project_id: id} do
    :ok = Neumu.subscribe(id)

    assert {:ok, 2} = Neumu.insert_tempo_step(id, "t0", 0, 120)
    # 排空成功编辑的事件，后续否定断言才有意义。
    assert_received {:project_changed, ^id, 2}

    assert {:error, {:tempo_tick_occupied, 0}} = Neumu.insert_tempo_step(id, "t1", 0, 90)
    assert {:error, {:invalid_bpm, -5}} = Neumu.insert_tempo_step(id, "t2", 480, -5)
    assert {:error, {:invalid_tick, -1}} = Neumu.insert_tempo_step(id, "t3", -1, 120)
    assert {:error, {:tempo_first_protected, "t0"}} = Neumu.delete_tempo_step(id, "t0")
    assert {:error, _} = Neumu.edit_tempo_step(id, "ghost", 90)

    assert {:ok, 2} = Neumu.history_pin(id)
    refute_received {:project_changed, _, _}
  end

  test "保存重开恢复 tempo 阶梯", %{project_id: id, tmp_dir: tmp_dir} do
    {registry, _stock} = ProjectStub.stock_registry(tmp_dir)

    assert {:ok, _} = Neumu.insert_tempo_step(id, "t0", 0, 60)
    assert {:ok, _} = Neumu.insert_tempo_step(id, "t1", 960, 90)

    path = Path.join(tmp_dir, "tempo.ncp")
    assert {:ok, ^path} = Neumu.save_project(id, path)

    reopened = "project-#{System.unique_integer([:positive])}"

    assert {:ok, _pid} =
             Neumu.load_project(
               reopened,
               path,
               ProjectStub.open_opts(registry, tmp_dir, PhonemesClient)
             )

    on_exit(fn ->
      if Neumu.ProjectServer.whereis(reopened), do: Neumu.close_project(reopened)
    end)

    assert [{"t0", 0, 60_000}, {"t1", 960, 90_000}] = steps(reopened)
    assert {:ok, 2.0} = Neumu.region_duration_sec(reopened, 0, 960)
  end

  test "未知工程 tagged error", %{tmp_dir: _tmp_dir} do
    assert {:error, {:unknown_project, :nope}} = Neumu.insert_tempo_step(:nope, "t0", 0, 120)
    assert {:error, {:unknown_project, :nope}} = Neumu.edit_tempo_step(:nope, "t0", 90)
    assert {:error, {:unknown_project, :nope}} = Neumu.delete_tempo_step(:nope, "t0")
    assert {:error, {:unknown_project, :nope}} = Neumu.region_duration_sec(:nope, 0, 960)
  end
end
