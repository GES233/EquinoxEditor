defmodule Neume.WindowingTest do
  use ExUnit.Case, async: true

  alias Neume.Windowing
  alias Neume.Windowing.Window

  # tpqn 480：一拍 = 480 tick，3 拍阈值 = 1440 tick
  @beat 480

  defp split(spans, opts \\ []) do
    spans
    |> Enum.with_index(1)
    |> Enum.map(fn {span, index} -> {"n#{index}", span} end)
    |> Windowing.split(Keyword.merge([tpqn: @beat], opts))
  end

  test "空轨无窗" do
    assert Windowing.split([]) == []
  end

  test "单音符一窗" do
    assert [%Window{start_tick: 0, end_tick: 480, note_ids: ["n1"]}] = split([{0, 480}])
  end

  test "小于 3 拍的空档粘连进同一窗" do
    # gap = 1439 < 1440
    assert [%Window{start_tick: 0, end_tick: 2399, note_ids: ["n1", "n2"]}] =
             split([{0, 480}, {960, 2399}])

    # gap = 480（一拍）也粘连
    assert [%Window{note_ids: ["n1", "n2"]}] = split([{0, 480}, {960, 1440}])
  end

  test "恰好 3 拍的空档切开，前 1 拍归前窗、后 2 拍归后窗" do
    # gap = 1440 = 3 拍：前窗延伸到 480+480=960，后窗提前到 1920-960=960
    assert [
             %Window{start_tick: 0, end_tick: 960, note_ids: ["n1"]},
             %Window{start_tick: 960, end_tick: 2400, note_ids: ["n2"]}
           ] = split([{0, 480}, {1920, 2400}])
  end

  test "超过 3 拍的空档中间留死区" do
    # gap = 2880（6 拍）：前窗 0..960，死区 960..2400，后窗 2400..3840
    assert [
             %Window{start_tick: 0, end_tick: 960, note_ids: ["n1"]},
             %Window{start_tick: 2400, end_tick: 3840, note_ids: ["n2"]}
           ] = split([{0, 480}, {3360, 3840}])
  end

  test "多窗链式切分" do
    spans = [{0, 480}, {960, 1440}, {4800, 5280}, {5760, 6240}, {9600, 10_080}]

    assert [
             %Window{note_ids: ["n1", "n2"]},
             %Window{note_ids: ["n3", "n4"]},
             %Window{note_ids: ["n5"]}
           ] = split(spans)
  end

  test "beat_ticks 选项优先于 tpqn" do
    # beat = 240：threshold = 720；gap = 720 → 切
    assert [%Window{note_ids: ["n1"]}, %Window{note_ids: ["n2"]}] =
             split([{0, 480}, {1200, 1680}], beat_ticks: 240)

    # 默认 beat = 480：threshold = 1440；gap = 720 → 粘
    assert [%Window{note_ids: ["n1", "n2"]}] = split([{0, 480}, {1200, 1680}])
  end

  test "乱序输入按 start 排序" do
    assert [%Window{note_ids: ["n2", "n1"]}] =
             Windowing.split([{"n1", {960, 1440}}, {"n2", {0, 480}}], tpqn: @beat)
  end
end
