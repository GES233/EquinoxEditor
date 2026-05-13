defmodule EquinoxDomain.TempoLinearTest do
  use ExUnit.Case

  alias EquinoxDomain.Timeline.{Tempo, TempoMap, Tick}
  import Tick

  @tpqn Tick.ticks_per_quarter_note()

  describe "build_from_event/3" do
    test "创建线性变速段" do
      assert {:ok, seg} =
               Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: 60})

      assert seg.bpm_start == 120
      assert seg.bpm_end == 60
      assert seg.start_tick == 0
      assert seg.end_tick == 1920
    end

    test "bpm_start 无效：零" do
      assert {:error, {:invalid_bpm_start, 0}} =
               Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 0, bpm_end: 60})
    end

    test "bpm_start 无效：负数" do
      assert {:error, {:invalid_bpm_start, -10}} =
               Tempo.Linear.build_from_event(0, 1920, %{bpm_start: -10, bpm_end: 60})
    end

    test "bpm_start 无效：非数字" do
      assert {:error, {:invalid_bpm_start, "fast"}} =
               Tempo.Linear.build_from_event(0, 1920, %{bpm_start: "fast", bpm_end: 60})
    end

    test "bpm_end 无效：零" do
      assert {:error, {:invalid_bpm_end, 0}} =
               Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: 0})
    end

    test "bpm_end 无效：负数" do
      assert {:error, {:invalid_bpm_end, -5}} =
               Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: -5})
    end

    test "bpm_end 无效：非数字" do
      assert {:error, {:invalid_bpm_end, "slow"}} =
               Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: "slow"})
    end
  end

  describe "duration_sec/1" do
    test "有限段：120到60，1920 ticks" do
      {:ok, seg} = Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: 60})
      duration = Tempo.Linear.duration_sec(seg)

      dur_at_120 = 1920 * (60.0 / 120) / @tpqn
      dur_at_60 = 1920 * (60.0 / 60) / @tpqn
      assert duration > dur_at_120
      assert duration < dur_at_60
    end

    test "恒定 BPM（退化为 Step）" do
      {:ok, seg} = Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: 120})
      duration = Tempo.Linear.duration_sec(seg)
      assert_in_delta duration, 2.0, 0.001
    end

    test "拒绝动态终点" do
      assert {:error, :linear_requires_finite_end_tick} =
               Tempo.Linear.build_from_event(0, get_dynamic_tick(), %{bpm_start: 120, bpm_end: 60})
    end
  end

  describe "tick_to_sec/2" do
    test "偏移 0 -> 0.0" do
      {:ok, seg} = Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: 60})
      assert Tempo.Linear.tick_to_sec(seg, 0) == 0.0
    end

    test "减速 120->60，中点 960 ticks" do
      {:ok, seg} = Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: 60})
      sec = Tempo.Linear.tick_to_sec(seg, 960)

      assert sec > 1.0
      assert sec < 2.0
    end

    test "加速 60->120，中点 960 ticks" do
      {:ok, seg} = Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 60, bpm_end: 120})
      sec = Tempo.Linear.tick_to_sec(seg, 960)

      assert sec < 2.0
      assert sec > 1.0
    end

    test "恒定 BPM：与 Step 一致" do
      {:ok, lin} = Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: 120})
      {:ok, step} = Tempo.Step.build_from_event(0, 1920, %{bpm: 120})

      assert_in_delta Tempo.Linear.tick_to_sec(lin, 480), Tempo.Step.tick_to_sec(step, 480), 0.001

      assert_in_delta Tempo.Linear.tick_to_sec(lin, 1920),
                      Tempo.Step.tick_to_sec(step, 1920),
                      0.001
    end
  end

  describe "sec_to_tick/2" do
    test "偏移 0.0 -> 0" do
      {:ok, seg} = Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: 60})
      assert Tempo.Linear.sec_to_tick(seg, 0.0) == 0
    end

    test "恒定 BPM：sec 0.5 -> tick 480" do
      {:ok, seg} = Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: 120})
      assert Tempo.Linear.sec_to_tick(seg, 0.5) == 480
    end

    test "恒定 BPM：sec 2.0 -> tick 1920" do
      {:ok, seg} = Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: 120})
      assert Tempo.Linear.sec_to_tick(seg, 2.0) == 1920
    end

    test "往返一致性：加速" do
      {:ok, seg} = Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 60, bpm_end: 120})

      for ticks <- [0, 240, 480, 960, 1440, 1920] do
        sec = Tempo.Linear.tick_to_sec(seg, ticks)
        roundtrip = Tempo.Linear.sec_to_tick(seg, sec)
        assert_in_delta Tempo.Linear.tick_to_sec(seg, roundtrip), sec, 0.001
      end
    end

    test "往返一致性：减速" do
      {:ok, seg} = Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: 60})

      for ticks <- [0, 240, 480, 960, 1440, 1920] do
        sec = Tempo.Linear.tick_to_sec(seg, ticks)
        roundtick = Tempo.Linear.sec_to_tick(seg, sec)
        assert_in_delta Tempo.Linear.tick_to_sec(seg, roundtick), sec, 0.001
      end
    end

    test "sec 超出有限段范围：回退到最后" do
      {:ok, seg} = Tempo.Linear.build_from_event(0, 1920, %{bpm_start: 120, bpm_end: 120})
      duration = Tempo.Linear.duration_sec(seg)
      tick = Tempo.Linear.sec_to_tick(seg, duration + 100.0)
      assert tick >= 1920
    end
  end

  describe "TempoMap 集成" do
    test "单个 Linear 段编译" do
      {:ok, compiled} =
        TempoMap.compile(
          {[
             {0, %Tempo.Event{module: Tempo.Linear, context: %{bpm_start: 120, bpm_end: 60}}}
           ], 3840}
        )

      assert tuple_size(compiled) == 1
      seg = elem(compiled, 0)
      assert seg.start_pos == 0
      assert seg.end_pos == 3840
      assert seg.start_sec == 0.0
      assert seg.strategy.bpm_start == 120
      assert seg.strategy.bpm_end == 60
    end

    test "Step + Linear 混合编译" do
      {:ok, compiled} =
        TempoMap.compile(
          {[
             {0, %Tempo.Event{module: Tempo.Step, context: %{bpm: 120}}},
             {1920, %Tempo.Event{module: Tempo.Linear, context: %{bpm_start: 120, bpm_end: 60}}}
           ], 3840}
        )

      assert tuple_size(compiled) == 2

      seg1 = elem(compiled, 0)
      assert seg1.strategy.bpm == 120
      assert seg1.end_pos == 1920

      seg2 = elem(compiled, 1)
      assert seg2.strategy.bpm_start == 120
      assert seg2.strategy.bpm_end == 60
      assert_in_delta seg2.start_sec, 2.0, 0.001
    end

    test "跨段 tick -> sec 正确累积" do
      {:ok, compiled} =
        TempoMap.compile(
          {[
             {0, %Tempo.Event{module: Tempo.Step, context: %{bpm: 120}}},
             {1920, %Tempo.Event{module: Tempo.Linear, context: %{bpm_start: 120, bpm_end: 60}}}
           ], 3840}
        )

      assert_in_delta TempoMap.tick_to_sec(compiled, 480), 0.5, 0.001
      assert_in_delta TempoMap.tick_to_sec(compiled, 1920), 2.0, 0.001

      sec = TempoMap.tick_to_sec(compiled, 1920 + 960)
      assert sec > 3.0
      assert sec < 4.0
    end

    test "往返一致性" do
      {:ok, compiled} =
        TempoMap.compile(
          {[
             {0, %Tempo.Event{module: Tempo.Step, context: %{bpm: 120}}},
             {1920, %Tempo.Event{module: Tempo.Linear, context: %{bpm_start: 120, bpm_end: 60}}}
           ], 3840}
        )

      for tick <- [0, 480, 1920, 2400, 3000] do
        sec = TempoMap.tick_to_sec(compiled, tick)
        roundtrip = TempoMap.sec_to_tick(compiled, sec)
        assert_in_delta TempoMap.tick_to_sec(compiled, roundtrip), sec, 0.001
      end
    end
  end

  describe "序列化往返" do
    alias EquinoxDomain.Util.Pickle.Plugable

    test "dump/load 往返" do
      event = %Tempo.Event{module: Tempo.Linear, context: %{bpm_start: 120, bpm_end: 60}}

      {:ok, tagged} = Plugable.dispatch_dump(event, Tempo.scope(), Tempo.Linear)

      assert tagged["__scope__"] == Tempo.scope()
      assert tagged["__signature__"] == "Linear"
      assert tagged["bpm_start"] == 120
      assert tagged["bpm_end"] == 60

      registry = %{Tempo.scope() => %{"Linear" => Tempo.Linear}}
      {:ok, loaded} = Plugable.dispatch_load(tagged, Tempo.scope(), registry)

      assert loaded.module == Tempo.Linear
      assert loaded.context.bpm_start == 120
      assert loaded.context.bpm_end == 60
    end
  end
end
