defmodule EquinoxWeb.ProjectChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint EquinoxWeb.Endpoint

  setup do
    project_id = "ui-test-#{System.unique_integer([:positive])}"
    :ok = EquinoxWeb.Demo.open(project_id)
    token = Phoenix.Token.sign(@endpoint, "project", project_id)
    {:ok, socket} = connect(EquinoxWeb.UserSocket, %{"token" => token})

    {:ok, %{snapshot: snapshot}, socket} =
      subscribe_and_join(socket, "project:#{project_id}", %{})

    on_exit(fn -> Neumu.close_project(project_id) end)
    %{socket: socket, project_id: project_id, snapshot: snapshot}
  end

  test "真实编辑只落一条历史边，事件通知重查，撤销恢复", %{socket: socket, project_id: id, snapshot: original} do
    ref =
      push(socket, "edit", %{
        "command" => "edit_note",
        "track_id" => "lead",
        "note_id" => "n1",
        "changes" => %{"lyric" => "你好", "pitch" => 62}
      })

    assert_reply(ref, :ok, %{data: pin})
    assert pin == original.history_pin + 1
    assert_push("project_changed", %{project_id: ^id, history_pin: ^pin})
    assert {:ok, %{tracks: [%{notes: [%{lyric: "你好", pitch: 62}]}]}} = Neumu.snapshot(id)

    ref = push(socket, "edit", %{"command" => "undo"})
    assert_reply(ref, :ok, %{data: restored_pin})
    assert restored_pin == original.history_pin
    ref = push(socket, "snapshot", %{})
    assert_reply(ref, :ok, %{data: %{tracks: [%{notes: [%{lyric: "啦", pitch: 60}]}]}})
  end

  test "非法及未知字段不进入 facade，不修改快照", %{socket: socket, project_id: id, snapshot: original} do
    for changes <- [%{"pitch" => 60.5}, %{"pitch" => 128}, %{"surprise_atom" => 1}, %{}] do
      ref =
        push(socket, "edit", %{
          "command" => "edit_note",
          "track_id" => "lead",
          "note_id" => "n1",
          "changes" => changes
        })

      assert_reply(ref, :error, %{reason: ":invalid_note_changes"})
    end

    ref = push(socket, "edit", %{"command" => "anything"})
    assert_reply(ref, :error, %{reason: ":invalid_command"})
    assert {:ok, ^original} = Neumu.snapshot(id)
    refute_push("project_changed", _)
  end

  test "移动和声库绑定经 facade，可分别撤销", %{socket: socket, project_id: id} do
    ref =
      push(socket, "edit", %{
        "command" => "move_note",
        "track_id" => "lead",
        "note_id" => "n1",
        "span" => [600, 1080]
      })

    assert_reply(ref, :ok, %{data: _})
    assert {:ok, %{tracks: [%{notes: [%{start_tick: 600, end_tick: 1080}]}]}} = Neumu.snapshot(id)

    ref = push(socket, "voicebanks", %{})
    assert_reply(ref, :ok, %{data: [_, second]})

    ref =
      push(socket, "edit", %{
        "command" => "rebind_voicebank",
        "track_id" => "lead",
        "voicebank_id" => second.id
      })

    assert_reply(ref, :ok, %{data: _})
    assert {:ok, %{tracks: [%{voicebank: %{name: "演示声库 B"}}]}} = Neumu.snapshot(id)
    ref = push(socket, "edit", %{"command" => "undo"})
    assert_reply(ref, :ok, %{data: _})

    assert {:ok, %{tracks: [%{voicebank: %{name: "演示声库 A"}, notes: [%{start_tick: 600}]}]}} =
             Neumu.snapshot(id)
  end

  test "重连只读取工程，不重复创建种子音符", %{project_id: id, snapshot: original} do
    assert :ok = EquinoxWeb.Demo.open(id)
    token = Phoenix.Token.sign(@endpoint, "project", id)
    assert {:ok, socket} = connect(EquinoxWeb.UserSocket, %{"token" => token})
    assert {:ok, %{snapshot: ^original}, _} = subscribe_and_join(socket, "project:#{id}", %{})
  end

  test "令牌限定工程，未知或伪造令牌被拒绝", %{project_id: id} do
    assert :error = connect(EquinoxWeb.UserSocket, %{"token" => "invalid"})
    assert :error = connect(EquinoxWeb.UserSocket, %{})
    token = Phoenix.Token.sign(@endpoint, "project", id)
    {:ok, socket} = connect(EquinoxWeb.UserSocket, %{"token" => token})
    assert {:error, %{reason: ":unauthorized"}} = subscribe_and_join(socket, "project:other", %{})
  end
end
