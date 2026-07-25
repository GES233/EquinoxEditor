defmodule EquinoxDomain.Pickle.TrackTest do
  use ExUnit.Case, async: true

  import EquinoxDomain.PickleTestHelper

  alias EquinoxDomain.Port.Declarations.PhonemeTiming
  alias EquinoxDomain.Port.Preset
  alias EquinoxDomain.Score.Track
  alias Zongzi.Intervention
  alias Zongzi.Score.Key.TwelveET

  @tpqn 480
  @projection %{"C" => [0.0, 0.05], "V" => [0.05, 0.10]}

  defp insert(track, key, start_tick, duration \\ @tpqn) do
    {:ok, track, note} =
      Track.insert_note(track,
        start_tick: start_tick,
        duration_tick: duration,
        key: key,
        lyric: "a"
      )

    {track, note}
  end

  # 场景：插 4 音符 → 删第 2 个（墓碑）→ 切第 3 个 → 在切出的后半音符上挂干预，
  # 再写上 presets / 标量字段，构成一个有代表性的脏 Track
  setup do
    {:ok, track} =
      Track.new(id: "Track_t1", project_id: "Project_p1", name: "主唱")

    {:ok, key} = TwelveET.new(60)

    {track, _a} = insert(track, key, 0)
    {track, b} = insert(track, key, 960)
    {track, c} = insert(track, key, 1920)
    {track, _d} = insert(track, key, 2880)

    {:ok, track} = Track.delete_note(track, b.seq_id)
    {:ok, track, _before, after_note} = Track.split_note(track, c.seq_id, 2160)

    {:ok, int} =
      Intervention.new(
        id: "iv_roundtrip",
        channel: PhonemeTiming.channel(),
        declaration: PhonemeTiming
      )

    payload = %{
      range: [2160, 2400],
      deltas: [%{identity: "V", onset_delta_ms: 20, duration_delta_ms: 0}]
    }

    {:ok, track, _mounted} =
      Track.mount_intervention(track, int, payload, after_note.seq_id, @projection)

    {:ok, preset} =
      Preset.new(
        name: "默认",
        declarations: %{phoneme_timing: PhonemeTiming},
        artifact: [:phoneme_timing],
        allow_adopt: [:phoneme_timing],
        metadata: %{note: "测试"}
      )

    {:ok, track} =
      Track.update(track,
        gain: 0.8,
        pan: -0.5,
        mute: true,
        presets: %{"默认" => preset},
        active_preset: "默认",
        metadata: %{"lang" => "zh"}
      )

    %{track: track}
  end

  test "dump 产物 plain 且形状符合约定", %{track: track} do
    assert {:ok, dump} = Track.dump(track)
    assert_plain!(dump)

    assert dump.id == "Track_t1"
    assert dump.type == :synth
    assert dump.gain == 0.8
    assert dump.mute == true
    # timeline 不含 track_id（由宿主注入）
    refute Map.has_key?(dump.timeline, :track_id)
    assert dump.timeline.tombstones != []
    # notes_by_seq 的整数 seq 键原生保留
    assert Enum.all?(Map.keys(dump.notes_by_seq), &is_integer/1)
    # interventions 是 dump list，anchor 已转 list
    assert [%{anchor: [_, _, _]}] = dump.interventions
    # presets 摊平
    assert dump.presets["默认"].declarations == %{phoneme_timing: PhonemeTiming}
  end

  test "load(dump(track)) 结构全等：timeline / notes_by_seq / interventions / presets",
       %{track: track} do
    assert {:ok, dump} = Track.dump(track)
    assert {:ok, loaded} = Track.load(dump)

    assert loaded == track
  end

  test "行为断言：round-trip 后切片结果一致", %{track: track} do
    assert {:ok, dump} = Track.dump(track)
    assert {:ok, loaded} = Track.load(dump)

    assert {:ok, segments} = Track.slice(track)
    assert {:ok, ^segments} = Track.slice(loaded)
  end

  test "干预存活：loaded 上的 intervention 与 original 全等（含 snapshot/anchor）",
       %{track: track} do
    assert {:ok, dump} = Track.dump(track)
    assert {:ok, loaded} = Track.load(dump)

    assert loaded.interventions == track.interventions
    assert [mounted] = loaded.interventions
    assert mounted.anchor |> is_tuple()
    assert mounted.payload.range == [2160, 2400]
    assert mounted.snapshot == %{"V" => [0.05, 0.10]}
  end

  test "Preset 独立 round-trip" do
    {:ok, preset} =
      Preset.new(
        name: "p",
        declarations: %{phoneme_timing: PhonemeTiming},
        artifact: [:phoneme_timing],
        allow_adopt: []
      )

    assert {:ok, dump} = Preset.dump(preset)
    assert_plain!(dump)
    assert {:ok, loaded} = Preset.load(dump)
    assert loaded == preset
  end

  test "load 损坏的子结构（非法 note dump）向上返回 error", %{track: track} do
    assert {:ok, dump} = Track.dump(track)
    [seq | _] = Map.keys(dump.notes_by_seq)
    bad = put_in(dump.notes_by_seq[seq].start_tick, -1)

    assert {:error, {:invalid_negative_tick, -1}} = Track.load(bad)
  end
end
