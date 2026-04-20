defmodule Equinox.ProjectTest do
  use ExUnit.Case, async: true
  alias Equinox.Project

  describe "Project" do
    test "new/1 creates a project with default values" do
      project = Project.new()
      assert project.name == "Untitled Project"
      assert project.version == 1
      assert length(project.tempo_map) == 1
      assert project.tracks == %{}
    end

    test "new/1 accepts custom values" do
      project = Project.new(%{name: "My Song", version: 2})
      assert project.name == "My Song"
      assert project.version == 2
    end

    test "JSON encoding" do
      project = Project.new(%{name: "Test JSON"})
      json = Jason.encode!(project)
      assert json =~ "Test JSON"
      assert json =~ "tempo_map"
      assert json =~ "tracks"
    end
  end

  describe "Project JSON Conversion" do
    test "to_json and from_json are symmetrical" do
      original =
        Project.new(%{
          name: "My Symmetrical Song",
          tempo_map: [%{tick: 0, bpm: 110.0}, %{tick: 1920, bpm: 125.0}],
          tracks: %{
            "track_1" =>
              Equinox.Track.new(%{
                id: "track_1",
                name: "Main Vocal",
                gain: 0.8,
                ui_state: %{arranger_position: %{x: 50, y: 30}},
                segments: %{
                  "seg_1" =>
                    Equinox.Domain.Segment.new(%{
                      id: "seg_1",
                      offset_tick: 480,
                      synth_override: %{provider: "default"},
                      notes: [
                        Equinox.Domain.Note.new(%{
                          start_tick: 0,
                          duration_tick: 240,
                          key: 60,
                          lyric: "a"
                        }),
                        Equinox.Domain.Note.new(%{
                          start_tick: 240,
                          duration_tick: 480,
                          key: 62,
                          lyric: "ha"
                        })
                      ],
                      curves: %{"pitch" => []}
                    })
                }
              })
          }
        })

      json = Project.to_json(original)
      parsed = Project.from_json(json)

      assert parsed.name == "My Symmetrical Song"
      assert length(parsed.tempo_map) == 2

      track = parsed.tracks[:track_1]
      assert track.name == "Main Vocal"
      assert track.gain == 0.8
      assert track.ui_state[:arranger_position][:x] == 50

      segment = track.segments[:seg_1]
      assert segment.offset_tick == 480
      assert segment.synth_override[:provider] == "default"
      assert length(segment.notes) == 2

      note = hd(segment.notes)
      assert note.key == 60
      assert note.lyric == "a"
    end
  end
end
