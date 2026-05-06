defmodule EquinoxDomain.TimeSigMapTest do
  use ExUnit.Case

  alias EquinoxDomain.Timeline.TimeSigMap
  doctest TimeSigMap

  describe "compile/1" do
    test "空列表" do
      assert TimeSigMap.compile([]) == {:error, :empty_time_sig_events}
    end

    test "首个事件不在 bar 1" do
      events = [{2, {:standard, 4, 4}}]
      assert {:error, {:first_record_must_start_at_zero, 1}} = TimeSigMap.compile(events)
    end

    test "单拍号 4/4" do
      {:ok, compiled} =
        TimeSigMap.compile([
          {1, {:standard, 4, 4}}
        ])

      assert tuple_size(compiled) == 1
      seg = elem(compiled, 0)
      assert seg.start_pos == 0
      assert seg.end_pos == :open_end
      assert seg.start_bar == 1
      assert seg.start_tick == 0
      assert seg.end_tick == :dynamic_tick
      assert seg.time_sig == {:standard, 4, 4}
    end

    test "多拍号变化" do
      {:ok, compiled} =
        TimeSigMap.compile([
          {1, {:standard, 4, 4}},
          {3, {:standard, 3, 4}}
        ])

      assert tuple_size(compiled) == 2

      seg1 = elem(compiled, 0)
      assert seg1.start_bar == 1
      assert seg1.start_tick == 0
      assert seg1.end_pos == 2
      assert seg1.time_sig == {:standard, 4, 4}
      # 2 bars * 1920 ticks/bar = 3840 ticks
      assert seg1.end_tick == 3840

      seg2 = elem(compiled, 1)
      assert seg2.start_bar == 3
      assert seg2.start_tick == 3840
      assert seg2.end_pos == :open_end
      assert seg2.time_sig == {:standard, 3, 4}
    end

    test "复拍子" do
      {:ok, compiled} =
        TimeSigMap.compile([
          {1, {:compound, [3, 2], 8}}
        ])

      seg = elem(compiled, 0)
      assert seg.time_sig == {:compound, [3, 2], 8}
      assert seg.start_tick == 0
    end

    test "散拍子" do
      {:ok, compiled} =
        TimeSigMap.compile([
          {1, :san}
        ])

      seg = elem(compiled, 0)
      assert seg.time_sig == :san
      assert seg.end_tick == :dynamic_tick
    end
  end

  describe "bar_to_tick/2" do
    setup do
      {:ok, compiled} =
        TimeSigMap.compile([
          {1, {:standard, 4, 4}},
          {3, {:standard, 3, 4}}
        ])

      %{compiled: compiled}
    end

    test "bar 1 → tick 0", %{compiled: c} do
      assert TimeSigMap.bar_to_tick(c, 1) == {:ok, 0}
    end

    test "bar 2 → tick 1920", %{compiled: c} do
      assert TimeSigMap.bar_to_tick(c, 2) == {:ok, 1920}
    end

    test "bar 3（拍号变化）→ 正确 tick", %{compiled: c} do
      # bar 1-2: 2 bars * 1920 = 3840 ticks
      assert TimeSigMap.bar_to_tick(c, 3) == {:ok, 3840}
    end

    test "bar 4（3/4 拍号）→ tick 3840 + 1440", %{compiled: c} do
      # 3/4: ticks_per_bar = Tk.tpqn * 4 * 3 / 4 = 480 * 3 = 1440
      assert TimeSigMap.bar_to_tick(c, 4) == {:ok, 3840 + 1440}
    end

    test "超出范围回退", %{compiled: c} do
      assert {:ok, tick} = TimeSigMap.bar_to_tick(c, 100)
      assert tick >= 3840
    end

    test "无效 bar", %{compiled: c} do
      assert TimeSigMap.bar_to_tick(c, 0) == {:error, {:invalid_bar, 0}}
    end

    test "散拍子拒绝 bar_to_tick" do
      {:ok, compiled} = TimeSigMap.compile([{1, :san}])
      assert TimeSigMap.bar_to_tick(compiled, 1) == {:error, {:free_meter_at_bar, 1}}
    end
  end

  describe "tick_to_bar/2" do
    setup do
      {:ok, compiled} =
        TimeSigMap.compile([
          {1, {:standard, 4, 4}},
          {3, {:standard, 3, 4}}
        ])

      %{compiled: compiled}
    end

    test "tick 0 → bar 1", %{compiled: c} do
      assert TimeSigMap.tick_to_bar(c, 0) == {:ok, 1}
    end

    test "tick 1920 → bar 2", %{compiled: c} do
      assert TimeSigMap.tick_to_bar(c, 1920) == {:ok, 2}
    end

    test "tick 3839 → bar 2（边界）", %{compiled: c} do
      assert TimeSigMap.tick_to_bar(c, 3839) == {:ok, 2}
    end

    test "tick 3840 → bar 3", %{compiled: c} do
      assert TimeSigMap.tick_to_bar(c, 3840) == {:ok, 3}
    end

    test "tick 5280 → bar 4（3/4 内）", %{compiled: c} do
      # 3840 + 1440 = 5280, 落在 bar 4
      assert TimeSigMap.tick_to_bar(c, 5280) == {:ok, 4}
    end

    test "往返一致性 bar → tick → bar", %{compiled: c} do
      {:ok, tick} = TimeSigMap.bar_to_tick(c, 2)
      assert TimeSigMap.tick_to_bar(c, tick) == {:ok, 2}
    end

    test "散拍子拒绝 tick_to_bar" do
      {:ok, compiled} = TimeSigMap.compile([{1, :san}])
      assert TimeSigMap.tick_to_bar(compiled, 0) == {:error, {:free_meter_at_tick, 0}}
    end
  end
end
