defmodule EquinoxDomain.TempoMapTest do
  use ExUnit.Case

  alias EquinoxDomain.Timeline.{Tempo, TempoMap}

  describe "compile/1" do
    test "空列表" do
      assert TempoMap.compile([]) == {:error, :empty_tempo_events}
    end

    test "首个事件不在 0" do
      events = [{480, %Tempo.Event{module: Tempo.Step, context: %{bpm: 120}}}]
      assert {:error, {:first_tempo_event_must_start_at_zero, 480}} = TempoMap.compile(events)
    end

    test "单步阶梯（恒定速度）" do
      bpm = 120

      {:ok, compiled} =
        TempoMap.compile([
          {0, %Tempo.Event{module: Tempo.Step, context: %{bpm: bpm}}}
        ])

      assert tuple_size(compiled) == 1
      seg = elem(compiled, 0)
      assert seg.start_pos == 0
      assert seg.end_pos == :dynamic_tick
      assert seg.start_sec == 0.0
      assert seg.strategy.bpm == bpm
    end

    test "多步阶梯" do
      {:ok, compiled} =
        TempoMap.compile([
          {0, %Tempo.Event{module: Tempo.Step, context: %{bpm: 120}}},
          {1920, %Tempo.Event{module: Tempo.Step, context: %{bpm: 60}}}
        ])

      assert tuple_size(compiled) == 2

      seg1 = elem(compiled, 0)
      assert seg1.start_pos == 0
      assert seg1.end_pos == 1920
      assert seg1.start_sec == 0.0
      assert seg1.strategy.bpm == 120

      seg2 = elem(compiled, 1)
      assert seg2.start_pos == 1920
      assert seg2.end_pos == :dynamic_tick
      # 120 bpm: 1920 ticks = 2.0 sec (480 ticks/qn, 120 bpm → 0.5 sec/qn → 4 qn = 2.0 sec)
      assert_in_delta seg2.start_sec, 2.0, 0.001
      assert seg2.strategy.bpm == 60
    end
  end

  describe "tick_to_sec/2" do
    setup do
      {:ok, compiled} =
        TempoMap.compile([
          {0, %Tempo.Event{module: Tempo.Step, context: %{bpm: 120}}}
        ])

      %{compiled: compiled}
    end

    test "tick 0 → sec 0.0", %{compiled: c} do
      assert TempoMap.tick_to_sec(c, 0) == 0.0
    end

    test "480 ticks（四分音符，120 bpm）→ 0.5 sec", %{compiled: c} do
      assert_in_delta TempoMap.tick_to_sec(c, 480), 0.5, 0.001
    end

    test "1920 ticks（4 拍）→ 2.0 sec", %{compiled: c} do
      assert_in_delta TempoMap.tick_to_sec(c, 1920), 2.0, 0.001
    end
  end

  describe "sec_to_tick/2" do
    setup do
      {:ok, compiled} =
        TempoMap.compile([
          {0, %Tempo.Event{module: Tempo.Step, context: %{bpm: 120}}}
        ])

      %{compiled: compiled}
    end

    test "sec 0.0 → tick 0", %{compiled: c} do
      assert TempoMap.sec_to_tick(c, 0.0) == 0
    end

    test "sec 0.5 → tick 480", %{compiled: c} do
      assert TempoMap.sec_to_tick(c, 0.5) == 480
    end

    test "sec 2.0 → tick 1920", %{compiled: c} do
      assert TempoMap.sec_to_tick(c, 2.0) == 1920
    end
  end

  describe "多段速度转换" do
    setup do
      {:ok, compiled} =
        TempoMap.compile([
          {0, %Tempo.Event{module: Tempo.Step, context: %{bpm: 120}}},
          {1920, %Tempo.Event{module: Tempo.Step, context: %{bpm: 60}}}
        ])

      %{compiled: compiled}
    end

    test "第一段内 tick → sec", %{compiled: c} do
      # 120 bpm: 480 ticks = 0.5 sec
      assert_in_delta TempoMap.tick_to_sec(c, 480), 0.5, 0.001
    end

    test "第二段内 tick → sec", %{compiled: c} do
      # 第一段 1920 ticks = 2.0 sec (120 bpm)
      # 第二段从 1920 开始，60 bpm: 480 ticks = 1.0 sec
      # 所以 tick 1920+480=2400 → 2.0 + 1.0 = 3.0 sec
      assert_in_delta TempoMap.tick_to_sec(c, 2400), 3.0, 0.001
    end

    test "往返一致性", %{compiled: c} do
      sec = TempoMap.tick_to_sec(c, 1000)
      tick = TempoMap.sec_to_tick(c, sec)
      assert_in_delta TempoMap.tick_to_sec(c, tick), sec, 0.001
    end
  end
end
