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

    test "JSON encoding ignores graph and cluster" do
      segment =
        Segment.new(%{
          name: "Chorus",
          offset_tick: 1920,
          synth_override: %{provider: "diffsinger"},
          graph: %Equinox.Kernel.Graph{}
        })

      json = Jason.encode!(segment)

      assert json =~ "Chorus"
      assert json =~ "offset_tick"
      assert json =~ "synth_override"
      # Should not contain graph key since it's excluded in only: [...] list
      refute json =~ "graph"
    end
  end
end
