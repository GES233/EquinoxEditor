defmodule Equinox.EditorTest do
  use ExUnit.Case, async: true
  alias Equinox.Project
  alias Equinox.Editor
  alias Equinox.Editor.{Track, Segment}
  alias Equinox.Domain.Note

  setup do
    project =
      Project.new(%{
        name: "Test Project",
        tracks: %{
          "t1" =>
            Track.new(%{
              id: "t1",
              type: "synth",
              name: "Track 1",
              segments: %{
                "s1" =>
                  Segment.new(%{
                    id: "s1",
                    track_id: "t1",
                    notes: [
                      Note.new(%{
                        id: "n1",
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

    %{project: project}
  end

  describe "Note Operations" do
    test "add_note/4 adds a note to the correct segment", %{project: project} do
      new_note = Note.new(%{id: "n2", start_tick: 480, duration_tick: 240, key: 62, lyric: "ha"})
      {:ok, updated_project} = Editor.add_note(project, "t1", "s1", new_note)

      {:ok, track} = Project.get_track(updated_project, "t1")
      {:ok, segment} = Track.get_segment(track, "s1")
      assert length(segment.notes) == 2
      assert Enum.any?(segment.notes, fn n -> n.id == "n2" end)
    end

    test "update_note/5 updates a specific note's properties", %{project: project} do
      {:ok, updated_project} =
        Editor.update_note(project, "t1", "s1", "n1", %{lyric: "lu", duration_tick: 960})

      {:ok, track} = Project.get_track(updated_project, "t1")
      {:ok, segment} = Track.get_segment(track, "s1")

      note = Enum.find(segment.notes, fn n -> n.id == "n1" end)
      assert note.lyric == "lu"
      assert note.duration_tick == 960
      # key should be untouched
      assert note.key == 60
    end

    test "delete_note/4 removes a note entirely", %{project: project} do
      {:ok, updated_project} = Editor.delete_note(project, "t1", "s1", "n1")

      {:ok, track} = Project.get_track(updated_project, "t1")
      {:ok, segment} = Track.get_segment(track, "s1")
      assert segment.notes == []
    end
  end
end
