defmodule EquinoxUIShell.SessionHostTest do
  use ExUnit.Case, async: false

  alias Coconut.Edit.{History, Operations.InsertNote}
  alias Coconut.Score.Key.TwelveET
  alias Coconut.Util.ID
  alias Equinox.Session
  alias Equinox.Session.Server
  alias EquinoxDomain.Port.Channels.{Curve, PhonemeTiming}
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

  test "default_engine 注入 Stub 适配器：adopt 走真实门控与版本戳" do
    session_id = "ui-shell-engine-session"

    {:ok, project} =
      Project.new(id: ID.generate_id("Project_"), metadata: %{name: "Engine Wiring"})

    {:ok, project, _track} = Project.add_track(project, id: "Track_vocal", name: "Lead")

    {:ok, project} =
      seed_note(project, "Track_vocal", "Note_1", {0, 480}, 60)

    engine_config = %{
      voicebank_id: "ui_stub",
      engine_version: "0.1.0",
      channels: [:phoneme_timing, :curve],
      # 只声明 phoneme_timing 可采纳：curve 采纳必须被门控拦下
      adoptables: [:phoneme_timing]
    }

    assert {:ok, _pid} =
             SessionHost.start_session(session_id,
               project: project,
               default_engine: {EquinoxAdapters.Stub, engine_config}
             )

    on_exit(fn -> SessionHost.stop_session(session_id) end)

    server = Session.server(session_id)

    # 门控放行：phoneme_timing 在 adoptables 内
    assert {:ok, _track, patch} =
             Server.adopt_intervention(server, "Track_vocal",
               channel: PhonemeTiming,
               seq_id: "Note_1",
               payload: %{deltas: [%{identity: "ph_a", onset_delta_ms: 5, duration_delta_ms: 10}]}
             )

    # 版本戳真实盖进 digest base（与无引擎会话的未盖戳 digest 不同）
    assert patch.channel == :phoneme_timing
    assert is_binary(patch.patch.base_digest)

    # 门控拦截：curve 不在 adoptables 内
    {:ok, payload} =
      Curve.build_payload(:pitch, Coconut.Curve.Adapter.Bezier, [
        %{tick: 0, value: 62.0, handle_left: nil, handle_right: nil},
        %{tick: 240, value: 64.0, handle_left: nil, handle_right: nil}
      ])

    assert {:error, {:not_adoptable, :curve}} =
             Server.adopt_intervention(server, "Track_vocal",
               channel: Curve,
               anchor: {:ordinal, ["Note_1"]},
               payload: payload
             )

    assert :ok = SessionHost.stop_session(session_id)
    assert_session_gone(session_id)
  end

  # 经 coconut History 写入单个音符（与 kernel 写路径同源的夹具模式）
  defp seed_note(%Project{} = project, track_id, note_id, span, midi) do
    {:ok, key} = TwelveET.new(midi)

    req = %InsertNote{
      track_id: track_id,
      note_id: note_id,
      after_id: :head,
      span: span,
      attrs: %{pitch: key, lyric: "la"}
    }

    hist = History.new(project.workspace)

    case History.apply(hist, req) do
      {:ok, hist} -> {:ok, %{project | workspace: History.current(hist).workspace}}
      {:error, _} = err -> err
    end
  end
end
