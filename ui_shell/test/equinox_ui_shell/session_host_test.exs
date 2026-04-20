defmodule EquinoxUiShell.SessionHostTest do
  use ExUnit.Case, async: false

  alias Equinox.Project
  alias Equinox.Session
  alias EquinoxUiShell.SessionHost

  test "session host starts and stops session trees" do
    session_id = "ui-shell-session"
    project = Project.new(name: "UI Shell Session")

    assert {:error, :session_not_found} = Session.resolve(session_id)
    assert {:ok, _pid} = SessionHost.start_session(session_id, project: project)

    on_exit(fn ->
      SessionHost.stop_session(session_id)
    end)

    assert {:ok, server_pid} = Session.resolve(session_id)
    assert is_pid(server_pid)
    assert %Project{name: "UI Shell Session"} = GenServer.call(Session.server(session_id), {:get_project})

    assert {:error, {:already_started, _}} = SessionHost.start_session(session_id, project: project)
    assert :ok = SessionHost.stop_session(session_id)
    assert {:error, :session_not_found} = Session.resolve(session_id)
  end
end
