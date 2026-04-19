defmodule Equinox.Editor.TrackTest do
  use ExUnit.Case, async: true
  alias Equinox.Editor.Track

  describe "Track" do
    test "new/1 creates a track with default values" do
      track = Track.new()
      assert track.name == "New Track"
      assert track.color == "#3B82F6"
      assert track.gain == 1.0
      assert track.pan == 0.0
      assert track.mute == false
      assert track.solo == false
      assert track.insert_fx_chain == []
      assert track.ui_state == %{}
      assert track.parameters == %{}
      assert track.segments == %{}
    end

    test "JSON encoding" do
      track =
        Track.new(%{
          name: "Vocal",
          topology_ref: "diffsinger:v1",
          gain: 0.75,
          ui_state: %{arranger_position: %{x: 64, y: 96}}
        })

      json = Jason.encode!(track)
      assert json =~ "Vocal"
      assert json =~ "diffsinger:v1"
      assert json =~ "\"gain\":0.75"
      assert json =~ "arranger_position"
    end
  end
end
