defmodule EquinoxUIShell.SessionHostTest do
  use ExUnit.Case, async: false

  alias Coconut.Util.ID
  alias Equinox.Session
  alias Equinox.Session.Server
  alias EquinoxDomain.Score.Project
  alias EquinoxUIShell.SessionHost

  test "session host starts and stops session trees" do
    session_id = "ui-shell-session"

    {:ok, project} =
      Project.new(id: ID.generate_id("Project_"), metadata: %{name: "UI Shell Session"})

    assert {:error, :session_not_found} = Session.resolve(session_id)
    assert {:ok, _pid} = SessionHost.start_session(session_id, project: project)

    on_exit(fn ->
      SessionHost.stop_session(session_id)
    end)

    assert {:ok, server_pid} = Session.resolve(session_id)
    assert is_pid(server_pid)

    assert %{project: %Project{metadata: %{name: "UI Shell Session"}}} =
             Server.get_view(Session.server(session_id))

    assert {:error, {:already_started, _}} =
             SessionHost.start_session(session_id, project: project)

    assert :ok = SessionHost.stop_session(session_id)
    assert_session_gone(session_id)
  end

  # Registry 注销走 monitor 异步清理，terminate_child 返回后需短暂等待
  defp assert_session_gone(session_id, attempts \\ 20)
  defp assert_session_gone(_session_id, 0), do: flunk("session still registered after stop")

  defp assert_session_gone(session_id, attempts) do
    case Session.resolve(session_id) do
      {:error, :session_not_found} ->
        :ok

      {:ok, _pid} ->
        Process.sleep(10)
        assert_session_gone(session_id, attempts - 1)
    end
  end
end
