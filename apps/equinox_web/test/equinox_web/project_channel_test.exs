defmodule EquinoxWeb.ProjectChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint EquinoxWeb.Endpoint
  @moduletag capture_log: true

  defp token(socket) do
    ref = push(socket, "preflight_pin", %{"track_id" => "lead", "note_id" => "n1"})
    assert_reply(ref, :ok, %{data: token})
    Jason.decode!(Jason.encode!(token))
  end

  defp mount(socket, points) do
    push(socket, "edit", %{
      "command" => "mount_pitch",
      "track_id" => "lead",
      "note_id" => "n1",
      "points" => points,
      "token" => token(socket)
    })
  end

  test "音高挂载、改词与拖动存活、替换不叠加、移除可撤销", %{socket: socket, project_id: id} do
    ref = mount(socket, [[480, 60.25], [840, 62]])
    assert_reply(ref, :ok, %{data: 3})
    assert {:ok, %{tracks: [%{pins: [pin]}]}} = Neumu.snapshot(id)
    assert pin.payload.values == [[0, 60.25], [360, 62.0]]
    assert {:ok, _} = Neumu.edit_note(id, "lead", "n1", %{lyric: "改词", pitch: 64})
    assert {:ok, _} = Neumu.move_note(id, "lead", "n1", :head, {600, 1080})
    ref = push(socket, "check", %{})
    assert_reply(ref, :ok, %{data: %{status: :ok}}, 2000)

    ref =
      push(socket, "edit", %{
        "command" => "replace_pitch",
        "track_id" => "lead",
        "patch_id" => pin.id,
        "points" => [[0, 61], [240, 63]]
      })

    assert_reply(ref, :ok, %{data: %{history_pin: 6}})
    assert {:ok, %{tracks: [%{pins: [replacement]}]}} = Neumu.snapshot(id)
    refute replacement.id == pin.id

    ref =
      push(socket, "edit", %{
        "command" => "unmount_pitch",
        "track_id" => "lead",
        "note_id" => "n1"
      })

    assert_reply(ref, :ok, %{data: 7})
    assert {:ok, %{tracks: [%{pins: []}]}} = Neumu.snapshot(id)
    assert {:ok, 6} = Neumu.undo(id)
    assert {:ok, %{tracks: [%{pins: [^replacement]}]}} = Neumu.snapshot(id)
  end

  test "过期预检与客户端携带底料都拒绝且不落边", %{socket: socket, project_id: id} do
    stale = token(socket)
    {:ok, pin} = Neumu.edit_note(id, "lead", "n1", %{lyric: "新词"})

    ref =
      push(socket, "edit", %{
        "command" => "mount_pitch",
        "track_id" => "lead",
        "note_id" => "n1",
        "points" => [[480, 60]],
        "token" => stale
      })

    assert_reply(ref, :error, %{reason: reason})
    assert reason =~ "stale_pin"

    ref =
      push(socket, "edit", %{
        "command" => "mount_pitch",
        "track_id" => "lead",
        "note_id" => "n1",
        "points" => [[480, 60]],
        "token" => Map.put(token(socket), "base", %{})
      })

    assert_reply(ref, :error, %{reason: ":invalid_pin_token"})
    assert {:ok, ^pin} = Neumu.history_pin(id)
    assert {:ok, %{tracks: [%{pins: []}]}} = Neumu.snapshot(id)
  end

  test "越界控制点检查失败，重挂降级保留原件，重写恢复", %{socket: socket, project_id: id} do
    ref = mount(socket, [[480, 60], [1080, 62]])
    assert_reply(ref, :ok, %{data: pin})
    {:ok, original} = Neumu.snapshot(id)
    [patch] = hd(original.tracks).pins
    ref = push(socket, "check", %{})
    assert_reply(ref, :ok, %{data: %{history_pin: ^pin, status: :failed, entries: entries}}, 2000)
    assert Enum.any?(entries, &match?(%{reason: [:pitch_point_outside_note, "n1", 1080]}, &1))
    assert {:ok, _json} = Jason.encode(entries)

    ref =
      push(socket, "edit", %{
        "command" => "repatch",
        "track_id" => "lead",
        "patch_ids" => [patch.id]
      })

    assert_reply(ref, :ok, %{data: %{history_pin: ^pin, results: [%{status: :degraded}]}}, 2000)
    assert {:ok, ^original} = Neumu.snapshot(id)

    ref =
      push(socket, "edit", %{
        "command" => "replace_pitch",
        "track_id" => "lead",
        "patch_id" => patch.id,
        "points" => [[0, 60], [360, 62]]
      })

    assert_reply(ref, :ok, %{data: %{history_pin: _}})
    ref = push(socket, "check", %{})
    assert_reply(ref, :ok, %{data: %{status: :ok}}, 2000)
  end

  test "兼容音高载体改词产生真实身份冲突，重挂重新签名", %{socket: socket, project_id: id} do
    {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")

    legacy = %{
      format: :pitch_curve_v1,
      adapter: :bezier,
      coord: :absolute_tick,
      value: :absolute_midi,
      points: [%{tick: 480, value: 60, handle_left: nil, handle_right: nil}]
    }

    {:ok, _} = Neumu.mount_pitch(id, "lead", "n1", legacy, token)
    {:ok, _} = Neumu.edit_note(id, "lead", "n1", %{lyric: "新"})
    ref = push(socket, "check", %{})
    assert_reply(ref, :ok, %{data: %{status: :failed, entries: entries}}, 2000)
    conflict = Enum.find(entries, &(&1.kind == :conflict))
    assert conflict.note_id == "n1"
    assert {:ok, _} = Jason.encode(entries)

    ref =
      push(socket, "edit", %{
        "command" => "repatch",
        "track_id" => "lead",
        "patch_ids" => [conflict.patch_id]
      })

    assert_reply(ref, :ok, %{data: %{results: [%{status: :repatched}]}}, 2000)
    ref = push(socket, "check", %{})
    assert_reply(ref, :ok, %{data: %{status: :ok}}, 2000)
  end

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
