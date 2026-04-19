defmodule Equinox.OverallTest do
  use ExUnit.Case, async: false

  alias Equinox.Domain.Note
  alias Equinox.Editor
  alias Equinox.Track
  alias Equinox.Editor.Segment
  alias Equinox.Kernel.StepRegistry
  alias Equinox.Project
  alias Equinox.Session

  test "overall kernel flow covers registry, editor operations, and session lifecycle" do
    assert {:ok, phonemizer_spec} = StepRegistry.lookup(:phonemizer)
    assert phonemizer_spec.inputs == [:notes]

    project =
      Project.new(%{
        name: "Overall Flow",
        tracks: %{
          "track_1" =>
            Track.new(%{
              id: "track_1",
              name: "Lead",
              segments: %{
                "segment_1" =>
                  Segment.new(%{
                    id: "segment_1",
                    track_id: "track_1",
                    notes: [
                      Note.new(%{
                        id: "note_1",
                        start_tick: 0,
                        duration_tick: 480,
                        key: 60,
                        lyric: "la"
                      })
                    ]
                  })
              }
            })
        }
      })

    {:ok, project} =
      Editor.add_note(
        project,
        "track_1",
        "segment_1",
        Note.new(%{id: "note_2", start_tick: 480, duration_tick: 240, key: 62, lyric: "ha"})
      )

    {:ok, project} =
      Editor.update_note(project, "track_1", "segment_1", "note_1", %{lyric: "lu"})

    {:ok, project} = Editor.update_track_mix(project, "track_1", gain: 0.75, pan: -0.2)
    {:ok, project} = Editor.update_track_ui_state(project, "track_1", :focused_segment_id, "segment_1")

    {:ok, track} = Project.get_track(project, "track_1")
    {:ok, segment} = Track.get_segment(track, "segment_1")

    assert length(segment.notes) == 2
    assert Enum.any?(segment.notes, &(&1.id == "note_1" and &1.lyric == "lu"))
    assert track.gain == 0.75
    assert track.pan == -0.2
    assert track.ui_state.focused_segment_id == "segment_1"

    session_id = "overall-session"
    assert {:error, :session_not_found} = Session.resolve(session_id)
    assert {:ok, _pid} = Session.start(session_id, project: project)

    on_exit(fn ->
      Session.stop(session_id)
    end)

    assert {:ok, server_pid} = Session.resolve(session_id)
    assert is_pid(server_pid)
    project_in_session = GenServer.call(Session.server(session_id), {:get_project})
    assert project_in_session.name == "Overall Flow"

    updated_project = %{project | name: "Overall Flow Updated"}
    assert :ok = GenServer.call(Session.server(session_id), {:update_project, updated_project})

    project_in_session = GenServer.call(Session.server(session_id), {:get_project})
    assert project_in_session.name == "Overall Flow Updated"

    assert {:error, {:already_started, _pid}} = Session.start(session_id, project: project)
    assert :ok = Session.stop(session_id)
    assert {:error, :session_not_found} = Session.resolve(session_id)
  end
end
