defmodule EquinoxDomain.WindowingTest do
  use ExUnit.Case, async: true

  alias Coconut.Score.Note
  alias EquinoxDomain.Score.SliceFlag
  alias EquinoxDomain.Windowing
  alias EquinoxDomain.Windowing.Window

  # beat = 480（opts 缺省）；3 拍阈值 = 1440
  @beat 480

  defp note(id, flag) do
    {:ok, note} = Note.new(%{id: id})
    {:ok, note} = SliceFlag.set(note, flag)
    note
  end

  defp item(id, start_tick, end_tick, flag \\ :auto),
    do: {id, note(id, flag), {start_tick, end_tick}}

  defp windows(items, opts \\ []) do
    {:ok, windows} = Windowing.slice(items, opts)
    windows
  end

  defp shapes(windows),
    do:
      Enum.map(windows, fn %Window{start_tick: s, end_tick: e, note_ids: ids} -> {s, e, ids} end)

  describe "基准规则（RestSplit3Beats 移植）" do
    test "空输入得空窗" do
      assert windows([]) == []
    end

    test "单音符一窗" do
      assert shapes(windows([item("n1", 0, 480)])) == [{0, 480, ["n1"]}]
    end

    # gap 档位的表格化覆盖：1 拍 / 2 拍粘连，3 拍切开（前 1 拍归前窗、
    # 后 2 拍归后窗），4 拍切开留死区
    for {gap_beats, expected} <- [
          {1, :join},
          {2, :join},
          {3, :cut_no_dead_zone},
          {4, :cut_dead_zone}
        ] do
      test "空档 #{gap_beats} 拍 → #{expected}" do
        gap = unquote(gap_beats) * @beat
        n2_start = @beat + gap
        n2_end = n2_start + @beat

        result =
          shapes(windows([item("n1", 0, @beat), item("n2", n2_start, n2_end)]))

        case unquote(expected) do
          :join ->
            assert result == [{0, n2_end, ["n1", "n2"]}]

          :cut_no_dead_zone ->
            # 前 1 拍归前窗、后 2 拍归后窗，恰好接合无死区
            assert result == [{0, @beat + @beat, ["n1"]}, {@beat + @beat, n2_end, ["n2"]}]

          :cut_dead_zone ->
            left_end = @beat + @beat
            right_start = n2_start - 2 * @beat
            assert right_start > left_end
            assert result == [{0, left_end, ["n1"]}, {right_start, n2_end, ["n2"]}]
        end
      end
    end

    test "相邻音符（gap 0）粘连" do
      assert shapes(windows([item("n1", 0, 480), item("n2", 480, 960)])) ==
               [{0, 960, ["n1", "n2"]}]
    end

    test "和弦（同 start 两音符）并入同一窗" do
      assert shapes(windows([item("n1", 0, 480), item("n2", 0, 240)])) ==
               [{0, 480, ["n1", "n2"]}]
    end

    test "beat_ticks 选项改变阈值（beat=240 时 2 拍空档=480 仍粘连，3 拍切开）" do
      # beat=240：2 拍 gap=480 < 720 → 粘连
      assert shapes(windows([item("n1", 0, 240), item("n2", 720, 960)], beat_ticks: 240)) ==
               [{0, 960, ["n1", "n2"]}]

      # 3 拍 gap=720 → 切开
      assert shapes(windows([item("n1", 0, 240), item("n2", 960, 1200)], beat_ticks: 240)) ==
               [{0, 480, ["n1"]}, {480, 1200, ["n2"]}]
    end
  end

  describe "extra_spans（外部 content span 撑窗）" do
    test "extra span 填平大空档 → 两窗粘连成一窗" do
      items = [item("n1", 0, 480), item("n2", 2400, 2880)]

      assert shapes(windows(items, extra_spans: [{480, 2400}])) ==
               [{0, 2880, ["n1", "n2"]}]
    end

    test "与音符不相交的 extra span 自成一窗（note_ids 为空）" do
      items = [item("n1", 0, 480)]

      # gap 4520 ≥ 3 拍 → 切开：前窗 +1 拍得 [0, 960)，
      # extra span 窗 -2 拍起得 [4040, 6000)，中间死区
      assert shapes(windows(items, extra_spans: [{5000, 6000}])) ==
               [{0, 960, ["n1"]}, {5000 - 2 * @beat, 6000, []}]
    end

    test "extra span 与音符相交 → 扩展窗口边界" do
      items = [item("n1", 480, 960)]

      assert shapes(windows(items, extra_spans: [{240, 480}])) ==
               [{240, 960, ["n1"]}]
    end
  end

  describe "slice_flag 两遍修正" do
    test ":force_merge 跨 3 拍空档并窗" do
      items = [item("n1", 0, 480), item("n2", 1920, 2400, :force_merge)]

      assert shapes(windows(items)) == [{0, 2400, ["n1", "n2"]}]
    end

    test ":force_merge 链式合并（三连窗）" do
      items = [
        item("n1", 0, 480),
        item("n2", 1920, 2400, :force_merge),
        item("n3", 3840, 4320, :force_merge)
      ]

      assert shapes(windows(items)) == [{0, 4320, ["n1", "n2", "n3"]}]
    end

    test ":force_slice 在无空档处切窗" do
      items = [item("n1", 0, 480), item("n2", 480, 960, :force_slice)]

      assert shapes(windows(items)) == [{0, 480, ["n1"]}, {480, 960, ["n2"]}]
    end

    test ":force_slice 退化切点（和弦同 start）跳过" do
      items = [item("n1", 0, 480), item("n2", 0, 480, :force_slice)]

      assert shapes(windows(items)) == [{0, 480, ["n1", "n2"]}]
    end

    test ":force_slice 落在窗尾的切点（音符起点=窗内某 note 起点之外的边界）跳过" do
      # n2 与 n1 同 start（退化），n3 无 flag：整窗保持
      items = [item("n1", 0, 480), item("n2", 0, 240, :force_slice), item("n3", 480, 960)]

      assert shapes(windows(items)) == [{0, 960, ["n1", "n2", "n3"]}]
    end

    test "一窗内多个 :force_slice 逐一切" do
      items = [
        item("n1", 0, 480),
        item("n2", 480, 960, :force_slice),
        item("n3", 960, 1440, :force_slice)
      ]

      assert shapes(windows(items)) ==
               [{0, 480, ["n1"]}, {480, 960, ["n2"]}, {960, 1440, ["n3"]}]
    end

    test "修正顺序：先 force_merge 并窗，再 force_slice 切窗" do
      # n2 force_merge 把两窗并一；n3 force_slice 在并后的窗内下刀
      items = [
        item("n1", 0, 480),
        item("n2", 1920, 2400, :force_merge),
        item("n3", 2400, 2880, :force_slice)
      ]

      assert shapes(windows(items)) == [{0, 2400, ["n1", "n2"]}, {2400, 2880, ["n3"]}]
    end
  end

  describe "Window VO" do
    test "new/1 校验区间" do
      assert {:ok, %Window{start_tick: 0, end_tick: 480, note_ids: []}} =
               Window.new(%{start_tick: 0, end_tick: 480})

      assert {:error, {:invalid_window_span, _}} = Window.new(%{start_tick: 480, end_tick: 480})
      assert {:error, {:invalid_window_span, _}} = Window.new(%{start_tick: -1, end_tick: 480})
      assert {:error, {:invalid_window_span, _}} = Window.new(%{start_tick: 0})
    end

    test "update/2 更新字段并复验" do
      {:ok, window} = Window.new(%{start_tick: 0, end_tick: 480, note_ids: ["n1"]})

      assert {:ok, %Window{note_ids: ["n1", "n2"]}} =
               Window.update(window, note_ids: ["n1", "n2"])

      assert {:error, {:extra_attrs, _}} = Window.update(window, foo: 1)
    end
  end
end
