defmodule EquinoxDomain.RecordMapTest do
  use ExUnit.Case

  alias EquinoxDomain.Timeline.RecordMap

  # ---- 辅助 ----

  # 简单的 reducer：只记录值 + 计数器
  defp counting_reducer(start_pos, end_pos, value, count) do
    {:ok, %{start_pos: start_pos, end_pos: end_pos, value: value}, count + 1}
  end

  # ---- compile/3 验证 ----

  describe "compile/3 输入验证" do
    test "空列表" do
      assert RecordMap.compile([], &counting_reducer/4, 0) == {:error, :empty_records}
    end

    test "空列表带动态终点" do
      assert RecordMap.compile({[], :dynamic_tick}, &counting_reducer/4, 0) ==
               {:error, :empty_records}
    end

    test "首个 Record 位置不是 0" do
      assert {:error, {:first_record_must_start_at_zero, 480}} =
               RecordMap.compile(
                 [{480, :foo}],
                 &counting_reducer/4,
                 0
               )
    end

    test "有重复位置" do
      assert {:error, :duplicate_record_positions} =
               RecordMap.compile(
                 [{0, :a}, {480, :b}, {480, :c}],
                 &counting_reducer/4,
                 0
               )
    end

    test "位置不是非负整数" do
      assert {:error, {:invalid_record_position, _}} =
               RecordMap.compile(
                 [{0, :a}, {-1, :b}],
                 &counting_reducer/4,
                 0
               )
    end
  end

  # ---- compile/3 正常编译 ----

  describe "compile/3 正常编译" do
    test "单个 Record" do
      {:ok, tuple} =
        RecordMap.compile(
          [{0, :only}],
          &counting_reducer/4,
          0
        )

      assert tuple_size(tuple) == 1
      seg = elem(tuple, 0)
      assert seg.start_pos == 0
      assert seg.end_pos == :dynamic_tick
      assert seg.value == :only
    end

    test "两个 Record" do
      {:ok, tuple} =
        RecordMap.compile(
          [{0, :first}, {480, :second}],
          &counting_reducer/4,
          0
        )

      assert tuple_size(tuple) == 2

      assert elem(tuple, 0).start_pos == 0
      assert elem(tuple, 0).end_pos == 480
      assert elem(tuple, 0).value == :first

      assert elem(tuple, 1).start_pos == 480
      assert elem(tuple, 1).end_pos == :dynamic_tick
      assert elem(tuple, 1).value == :second
    end

    test "多个乱序 Record 自动排序" do
      {:ok, tuple} =
        RecordMap.compile(
          [{960, :c}, {0, :a}, {480, :b}],
          &counting_reducer/4,
          0
        )

      assert tuple_size(tuple) == 3
      assert elem(tuple, 0).value == :a
      assert elem(tuple, 1).value == :b
      assert elem(tuple, 2).value == :c
    end

    test "带动态最后的 Record 列表" do
      {:ok, tuple} =
        RecordMap.compile(
          {[{0, :first}, {480, :second}], :dynamic_tick},
          &counting_reducer/4,
          0
        )

      assert elem(tuple, 0).end_pos == 480
      assert elem(tuple, 1).end_pos == :dynamic_tick
    end

    test "累加器正确传递" do
      {:ok, tuple} =
        RecordMap.compile(
          [{0, :a}, {480, :b}, {960, :c}],
          fn start_pos, end_pos, value, count ->
            {:ok, %{start_pos: start_pos, end_pos: end_pos, value: value, index: count},
             count + 1}
          end,
          0
        )

      assert elem(tuple, 0).index == 0
      assert elem(tuple, 1).index == 1
      assert elem(tuple, 2).index == 2
    end
  end

  # ---- find_by_position/2 ----

  describe "find_by_position/2 二分查找" do
    setup do
      {:ok, tuple} =
        RecordMap.compile(
          [{0, :a}, {480, :b}, {960, :c}],
          &counting_reducer/4,
          0
        )

      %{tuple: tuple}
    end

    test "命中第一个区间", %{tuple: tuple} do
      seg = RecordMap.find_by_position(tuple, 0)
      assert seg.value == :a
    end

    test "命中第一个区间中间值", %{tuple: tuple} do
      seg = RecordMap.find_by_position(tuple, 240)
      assert seg.value == :a
    end

    test "命中第二个区间开头", %{tuple: tuple} do
      seg = RecordMap.find_by_position(tuple, 480)
      assert seg.value == :b
    end

    test "命中第三个区间", %{tuple: tuple} do
      seg = RecordMap.find_by_position(tuple, 1000)
      assert seg.value == :c
    end

    test "超出范围回退到最后一个区间", %{tuple: tuple} do
      seg = RecordMap.find_by_position(tuple, 9999)
      assert seg.value == :c
    end

    test "单区间直接命中" do
      {:ok, tuple} =
        RecordMap.compile(
          [{0, :only}],
          &counting_reducer/4,
          0
        )

      seg = RecordMap.find_by_position(tuple, 999)
      assert seg.value == :only
    end
  end

  # ---- reducer 错误传播 ----

  describe "reducer 错误传播" do
    test "reducer 返回错误时 compile 短路" do
      result =
        RecordMap.compile(
          [{0, :ok}, {480, :fail}, {960, :never_reached}],
          fn start_pos, end_pos, value, _acc ->
            if value == :fail do
              {:error, :intentional_fail}
            else
              {:ok, %{start_pos: start_pos, end_pos: end_pos, value: value}, :ignored}
            end
          end,
          :ignored
        )

      assert result == {:error, :intentional_fail}
    end
  end
end
