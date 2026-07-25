defmodule EquinoxDomain.Pickle.TempoEventsTest do
  use ExUnit.Case, async: true

  import EquinoxDomain.PickleTestHelper

  alias EquinoxDomain.Pickle
  alias Zongzi.Score.Tempo
  alias Zongzi.Score.Tempo.Event

  @events [
    {0, %Event{module: Tempo.Step, context: %{bpm: 120}}},
    {960, %Event{module: Tempo.Linear, context: %{bpm_start: 120, bpm_end: 60}}}
  ]

  test "纯列表形态：dump → %{events: [...]}（tuple → list），load 还原" do
    assert {:ok, dump} = Pickle.TempoEvents.dump(@events)
    assert_plain!(dump)

    assert dump == %{
             events: [
               [0, %{module: Tempo.Step, context: %{bpm: 120}}],
               [960, %{module: Tempo.Linear, context: %{bpm_start: 120, bpm_end: 60}}]
             ]
           }

    assert {:ok, loaded} = Pickle.TempoEvents.load(dump)
    assert loaded == @events
  end

  test "{events, last_tick} 形态：dump 带 last_tick，load 还原同形态" do
    assert {:ok, dump} = Pickle.TempoEvents.dump({@events, 1920})
    assert_plain!(dump)

    assert %{events: [_, _], last_tick: 1920} = dump

    assert {:ok, loaded} = Pickle.TempoEvents.load(dump)
    assert loaded == {@events, 1920}
  end

  test "last_tick 为 :dynamic_tick 时原子原生保留" do
    assert {:ok, dump} = Pickle.TempoEvents.dump({@events, :dynamic_tick})
    assert_plain!(dump)
    assert {:ok, loaded} = Pickle.TempoEvents.load(dump)
    assert loaded == {@events, :dynamic_tick}
  end

  test "空事件列表 round-trip" do
    assert {:ok, dump} = Pickle.TempoEvents.dump([])
    assert_plain!(dump)
    assert {:ok, []} = Pickle.TempoEvents.load(dump)
  end

  test "非法事件（非 Event struct）dump 报错" do
    assert {:error, {:invalid_tempo_event, {0, %{bpm: 120}}}} =
             Pickle.TempoEvents.dump([{0, %{bpm: 120}}])
  end

  test "非法输入（非列表/非二元组）dump 报错" do
    assert {:error, {:invalid_tempo_events, "nope"}} = Pickle.TempoEvents.dump("nope")
  end

  test "load 非法事件形状报错" do
    assert {:error, {:invalid_tempo_event_dump, _}} =
             Pickle.TempoEvents.load(%{events: [[0, %{no_module: true}]]})
  end
end
