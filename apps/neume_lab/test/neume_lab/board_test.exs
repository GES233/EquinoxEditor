defmodule NeumeLab.BoardTest do
  @moduledoc """
  实验台面板的 Kino.Test 矩阵：连接快照、编辑事件桥、冲突四步流
  （改词 → 冲突 → repatch → 恢复）、按 pin 渲染与二进制试听下发。
  """

  use ExUnit.Case, async: false

  import Kino.Test

  setup :configure_livebook_bridge

  @moduletag tmp_dir: true

  setup %{tmp_dir: tmp_dir} do
    demo = NeumeLab.Fixture.open_demo(dir: Path.join(tmp_dir, "lab"))

    on_exit(fn ->
      if Neumu.ProjectServer.whereis(demo.project_id), do: Neumu.close_project(demo.project_id)
    end)

    %{demo: demo}
  end

  defp start_board(demo), do: NeumeLab.Board.new(demo.project_id)

  test "连接即得全量状态：快照含演示音符，声库与任务列表就位", %{demo: demo} do
    kino = start_board(demo)
    data = connect(kino)

    assert data.project_id == demo.project_id
    assert [%{id: "lead", notes: notes}] = data.snapshot.tracks
    assert length(notes) == 4
    assert Enum.map(notes, & &1.lyric) == ["do", "re", "mi", "fa"]

    assert [%{id: stock_id, mode: :stock}] = data.voicebanks
    assert stock_id == demo.stock_id
    assert data.jobs == []
  end

  test "edit_lyric 经 facade 落账并广播新快照", %{demo: demo} do
    kino = start_board(demo)
    connect(kino)

    push_event(kino, "edit_lyric", %{"track_id" => "lead", "note_id" => "n1", "lyric" => "lu"})
    assert_broadcast_event(kino, "snapshot", snapshot, 1_000)

    [%{notes: notes}] = snapshot.tracks
    assert %{lyric: "lu"} = Enum.find(notes, &(&1.id == "n1"))
  end

  test "失败命令广播 command_error，状态不变", %{demo: demo} do
    kino = start_board(demo)
    connect(kino)

    push_event(kino, "edit_lyric", %{"track_id" => "lead", "note_id" => "ghost", "lyric" => "x"})
    assert_broadcast_event(kino, "command_error", %{op: "edit_lyric"}, 1_000)
    refute_broadcast_snapshot(kino)
  end

  test "未知事件不静默：回显 command_error", %{demo: demo} do
    kino = start_board(demo)
    connect(kino)

    push_event(kino, "bogus_event", %{"x" => 1})

    assert_broadcast_event(
      kino,
      "command_error",
      %{op: "unknown_event", reason: reason},
      1_000
    )

    assert reason =~ "bogus_event"
  end

  test "冲突四步流：挂 pin → 改词触发冲突 → 一键 repatch → 检查恢复", %{demo: demo} do
    kino = start_board(demo)
    connect(kino)

    # 1. 服务端一次走完 probe → mount；落边后广播快照，pin 投影在册。
    push_event(kino, "mount_duration", %{
      "track_id" => "lead",
      "note_id" => "n1",
      "durations" => [[0, 96]]
    })

    assert_broadcast_event(kino, "snapshot", snapshot, 1_000)
    assert [%{pins: [%{channel: :duration, anchor: %{refs: ["n1"]}}]}] = snapshot.tracks

    push_event(kino, "check", %{})
    assert_broadcast_event(kino, "check_result", %{status: :ok, entries: []}, 1_000)

    # 2. 改词改变输入底料 → check 失败，冲突条目携带 repatch 所需 identity。
    push_event(kino, "edit_lyric", %{"track_id" => "lead", "note_id" => "n1", "lyric" => "lu"})
    assert_broadcast_event(kino, "snapshot", _snapshot, 1_000)

    push_event(kino, "check", %{})

    assert_broadcast_event(
      kino,
      "check_result",
      %{
        status: :failed,
        entries: [%{track_id: "lead", patch_id: patch_id, reason: :base_changed} = entry]
      },
      1_000
    )

    # 壳层出界即 JSON-safe：phrase_id 已降为 list，整条目（含 reason）无
    # tuple/运行时对象——浏览器侧 JSON 序列化不会再炸。
    assert entry.phrase_id == ["lead", 0]
    assert_json_safe(entry)
    assert :json.encode(entry)

    # 3. 一键 repatch：repatch_result 与重查的 check_result 先后到达。
    push_event(kino, "repatch", %{"track_id" => "lead", "patch_ids" => [patch_id]})
    assert_broadcast_event(kino, "repatch_result", %{status: :ok}, 1_000)
    assert_broadcast_event(kino, "check_result", %{status: :ok, entries: []}, 1_000)
  end

  test "按 pin 渲染与二进制试听：任务列表刷新，play 下发 WAV", %{demo: demo} do
    kino = start_board(demo)
    data = connect(kino)
    pin = data.snapshot.history_pin

    push_event(kino, "render", %{"pin" => pin})
    assert_broadcast_event(kino, "jobs", [%{source_pin: ^pin, status: :running}], 1_000)

    assert_broadcast_event(
      kino,
      "jobs",
      [%{source_pin: ^pin, status: :completed, artifact_id: artifact_id}],
      10_000
    )

    assert is_binary(artifact_id)

    push_event(kino, "play", %{"artifact_id" => artifact_id})

    assert_broadcast_event(kino, "audio", {:binary, %{artifact_id: ^artifact_id}, wav}, 1_000)
    assert <<"RIFF", _rest::binary>> = wav
  end

  test "undo/redo 事件桥", %{demo: demo} do
    kino = start_board(demo)
    data = connect(kino)
    pin = data.snapshot.history_pin

    push_event(kino, "undo", %{})
    assert_broadcast_event(kino, "snapshot", %{history_pin: undone}, 1_000)
    assert undone == pin - 1

    push_event(kino, "redo", %{})
    assert_broadcast_event(kino, "snapshot", %{history_pin: ^pin}, 1_000)
  end

  # 事件断言需排空队列后再做否定断言，避免误判早到的广播。
  defp refute_broadcast_snapshot(kino) do
    %{ref: ref} = kino
    refute_received {:runtime_broadcast, "js_live", ^ref, {:event, "snapshot", _, _}}
  end

  # 壳层出界 payload 必须整体 JSON-safe：无 tuple、无运行时对象、无遗留
  # struct（facade 的 :reason 结构化契约到壳层为止，Board 已做末端转换）。
  defp assert_json_safe(term) when is_tuple(term), do: flunk("tuple 出界：#{inspect(term)}")

  defp assert_json_safe(term)
       when is_pid(term) or is_function(term) or is_reference(term) or is_port(term),
       do: flunk("运行时对象出界：#{inspect(term)}")

  defp assert_json_safe(%_{} = struct), do: flunk("struct 出界：#{inspect(struct)}")

  defp assert_json_safe(map) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      assert_json_safe_key(key)
      assert_json_safe(value)
    end)
  end

  defp assert_json_safe(list) when is_list(list), do: Enum.each(list, &assert_json_safe/1)
  defp assert_json_safe(_term), do: :ok

  defp assert_json_safe_key(key) when is_atom(key) or is_binary(key), do: :ok
  defp assert_json_safe_key(key), do: flunk("map key 不可 JSON 序列化：#{inspect(key)}")
end
