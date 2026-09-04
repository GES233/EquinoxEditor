defmodule CoconutOi.OrchidAdapter.AssembleTest do
  use ExUnit.Case, async: true

  alias CoconutOi.OrchidAdapter.Assemble

  @moduledoc """
  Covers the §3.2 aggregation rule: coconut's per-note intervention shape
  `%{port_ref => %{input: payload}}` (port_ref = `{:port, note_id, channel}`)
  is aggregated per stage into oi's nested data map. Interventions on the
  same stage collapse into a single `{type, %{note_id => payload}}` value.
  """

  @port_map %{
    lyric: {:duration, :phonemes},
    duration: {:pitch, :durations},
    pitch: {:input, :pitch, :pins}
  }

  test "no interventions yields an empty data map" do
    assert {:ok, %{}} = Assemble.assemble(%{}, @port_map)
  end

  test "a single-note intervention aggregates into one override value" do
    interventions = %{{:port, "n1", :lyric} => %{input: [["zh", "a"]]}}

    assert {:ok, data} = Assemble.assemble(interventions, @port_map)

    assert data == %{
             duration: %{phonemes: {:override, %{"n1" => [["zh", "a"]]}}}
           }
  end

  test "multiple notes on the same stage collapse into one aggregated map" do
    interventions = %{
      {:port, "n1", :lyric} => %{input: [["zh", "a"]]},
      {:port, "n2", :lyric} => %{input: [["zh", "o"]]}
    }

    assert {:ok, data} = Assemble.assemble(interventions, @port_map)

    assert data == %{
             duration: %{
               phonemes: {:override, %{"n1" => [["zh", "a"]], "n2" => [["zh", "o"]]}}
             }
           }
  end

  test "distinct channels land on distinct ports without cross-talk" do
    interventions = %{
      {:port, "n1", :lyric} => %{input: [["zh", "a"]]},
      {:port, "n1", :duration} => %{input: [[0, 480]]}
    }

    assert {:ok, data} = Assemble.assemble(interventions, @port_map)

    assert data == %{
             duration: %{phonemes: {:override, %{"n1" => [["zh", "a"]]}}},
             pitch: %{durations: {:override, %{"n1" => [[0, 480]]}}}
           }
  end

  test ":input mode aggregates without an intervention-type wrapper" do
    interventions = %{{:port, "n3", :pitch} => %{input: [{0, 440.0}]}}

    assert {:ok, data} = Assemble.assemble(interventions, @port_map)

    assert data == %{pitch: %{pins: %{"n3" => [{0, 440.0}]}}}
  end

  test "a custom Operate module as type is preserved in the wrapper" do
    port_map = %{pitch: {:acoustic, :f0, MyApp.PitchMerge}}
    interventions = %{{:port, "n1", :pitch} => %{input: :curve}}

    assert {:ok, data} = Assemble.assemble(interventions, port_map)

    assert data == %{acoustic: %{f0: {MyApp.PitchMerge, %{"n1" => :curve}}}}
  end

  test "channels absent from the port map are reported together" do
    interventions = %{
      {:port, "n1", :vibrato} => %{input: []},
      {:port, "n2", :gender} => %{input: []}
    }

    assert {:error, {:unknown_channels, channels}} = Assemble.assemble(interventions, @port_map)
    assert Enum.sort(channels) == [:gender, :vibrato]
  end

  test "malformed port refs are rejected" do
    assert {:error, {:invalid_port_ref, :nonsense}} =
             Assemble.assemble(%{nonsense: %{input: 1}}, @port_map)
  end
end
