defmodule EquinoxDomain.Pickle.TimeSigEventsTest do
  use ExUnit.Case, async: true

  import EquinoxDomain.PickleTestHelper

  alias EquinoxDomain.Pickle

  test "standard / compound / san 归一化编码，load 还原" do
    events = [
      {1, {4, 4}},
      {3, {:standard, 3, 4}},
      {5, {:compound, [2, 3], 8}},
      {7, :san}
    ]

    assert {:ok, dump} = Pickle.TimeSigEvents.dump(events)
    assert_plain!(dump)

    assert dump == %{
             events: [
               [1, ["standard", 4, 4]],
               [3, ["standard", 3, 4]],
               [5, ["compound", [2, 3], 8]],
               [7, "san"]
             ]
           }

    assert {:ok, loaded} = Pickle.TimeSigEvents.load(dump)

    # {4, 4} 与 {:standard, 4, 4} 编码相同，load 统一还原为规范形
    assert loaded == [
             {1, {:standard, 4, 4}},
             {3, {:standard, 3, 4}},
             {5, {:compound, [2, 3], 8}},
             {7, :san}
           ]
  end

  test "{events, end_bar} 形态 round-trip" do
    events = [{1, {:standard, 4, 4}}]

    assert {:ok, dump} = Pickle.TimeSigEvents.dump({events, 9})
    assert_plain!(dump)
    assert %{events: [[1, ["standard", 4, 4]]], end_bar: 9} = dump

    assert {:ok, loaded} = Pickle.TimeSigEvents.load(dump)
    assert loaded == {events, 9}
  end

  test "end_bar 为 :open_end 时原子原生保留" do
    events = [{1, {:standard, 4, 4}}]

    assert {:ok, dump} = Pickle.TimeSigEvents.dump({events, :open_end})
    assert_plain!(dump)
    assert {:ok, loaded} = Pickle.TimeSigEvents.load(dump)
    assert loaded == {events, :open_end}
  end

  test "非法 sig dump 报错" do
    assert {:error, {:invalid_time_sig, {:weird, 1}}} =
             Pickle.TimeSigEvents.dump([{1, {:weird, 1}}])
  end

  test "load 非法 sig 编码报错" do
    assert {:error, {:invalid_time_sig_dump, ["weird", 1]}} =
             Pickle.TimeSigEvents.load(%{events: [[1, ["weird", 1]]]})
  end
end
