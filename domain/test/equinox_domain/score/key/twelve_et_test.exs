defmodule EquinoxDomain.Score.Key.TwelveETTest do
  use ExUnit.Case

  alias EquinoxDomain.Score.{Key, Key.Inner}
  alias EquinoxDomain.Score.Key.TwelveET

  test "new/1 从 MIDI 编号构造" do
    {:ok, key} = Key.new(69, TwelveET)
    assert %TwelveET{midi: 69} = key
  end

  test "new/1 支持浮点" do
    {:ok, key} = Key.new(60.5, TwelveET)
    assert %TwelveET{midi: 60.5} = key
  end

  describe "from_midi/2" do
    test "整数 MIDI" do
      assert {:ok, %TwelveET{midi: 60}} = Key.from_midi(60, nil, TwelveET)
    end

    test "浮点 MIDI" do
      assert {:ok, %TwelveET{midi: 69.5}} = Key.from_midi(69.5, nil, TwelveET)
    end
  end

  describe "to_midi/1" do
    test "A4 (69)" do
      {:ok, key} = Key.new(69, TwelveET)
      assert Key.to_midi(key) == 69.0
    end

    test "C4 (60)" do
      {:ok, key} = Key.new(60, TwelveET)
      assert Key.to_midi(key) == 60.0
    end

    test "浮点 MIDI 保留精度" do
      {:ok, key} = Key.new(60.5, TwelveET)
      assert Key.to_midi(key) == 60.5
    end
  end

  describe "to_frequency/2" do
    test "A4 = 440 Hz" do
      {:ok, key} = Key.new(69, TwelveET)
      assert_in_delta Key.to_frequency(key, 440.0), 440.0, 0.01
    end

    test "A5 = 880 Hz" do
      {:ok, key} = Key.new(81, TwelveET)
      assert_in_delta Key.to_frequency(key, 440.0), 880.0, 0.01
    end

    test "A3 = 220 Hz" do
      {:ok, key} = Key.new(57, TwelveET)
      assert_in_delta Key.to_frequency(key, 440.0), 220.0, 0.01
    end

    test "C4 = ~261.63 Hz" do
      {:ok, key} = Key.new(60, TwelveET)
      assert_in_delta Key.to_frequency(key, 440.0), 261.6256, 0.1
    end

    test "不同参考频率" do
      {:ok, key} = Key.new(69, TwelveET)
      assert_in_delta Key.to_frequency(key, 432.0), 432.0, 0.01
    end

    test "半音差" do
      {:ok, c4} = Key.new(60, TwelveET)
      {:ok, cs4} = Key.new(61, TwelveET)
      # 频率比应接近 2^(1/12)
      ratio = Key.to_frequency(cs4, 440.0) / Key.to_frequency(c4, 440.0)
      assert_in_delta ratio, :math.pow(2, 1 / 12), 0.0001
    end
  end

  describe "序列化往返" do
    test "from_midi → to_midi 不丢失信息" do
      {:ok, key} = Key.from_midi(64, nil, TwelveET)
      assert Inner.to_midi(key) == 64.0
    end
  end
end
