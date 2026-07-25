defmodule Equinox.Domain.SegmentTest do
  use ExUnit.Case, async: true
  alias Equinox.Domain.Segment

  describe "Segment" do
    test "new/1 creates a segment with default values" do
      segment = Segment.new()
      assert segment.name == "New Segment"
      assert segment.offset_tick == 0
      assert segment.notes == []
      assert segment.curves == %{}
    end
  end
end
