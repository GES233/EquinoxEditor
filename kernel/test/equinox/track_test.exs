defmodule Equinox.TrackTest do
  use ExUnit.Case, async: true
  alias Equinox.Track

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
  end
end
