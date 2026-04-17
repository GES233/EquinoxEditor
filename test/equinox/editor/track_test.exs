defmodule Equinox.Editor.TrackTest do
  use ExUnit.Case, async: true
  alias Equinox.Editor.Track

  describe "Track" do
    test "new/1 creates a track with default values" do
      track = Track.new()
      assert track.name == "New Track"
      assert track.color == "#3B82F6"
      assert track.mute == false
      assert track.solo == false
      assert track.parameters == %{}
      assert track.segments == %{}
    end

    test "JSON encoding" do
      track = Track.new(%{name: "Vocal", topology_ref: "diffsinger:v1"})
      json = Jason.encode!(track)
      assert json =~ "Vocal"
      assert json =~ "diffsinger:v1"
    end
  end
end
