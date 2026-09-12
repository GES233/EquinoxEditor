defmodule Neume.MultiTrackNotePhonemesTest do
  @moduledoc """
  `Neume.MultiTrack.note_phonemes/1`（E0b facade 音素序列查询的内核）的
  单测矩阵：mock pipeline 下单音符投影、melisma 组头全组序列与续音符
  延续元音、多轨、空轨/空工程行为、probe 失败聚合投影。

  mock 音素派生：lyric 拆字（默认语言 zh），生效续音取头音符末音素当
  延续元音（与 `Neume.Engine.MockPipeline.phonemes/3` 同一约定）。
  """

  use ExUnit.Case, async: true

  alias Coconut.Edit.{Track, Workspace}
  alias Coconut.Project
  alias Neume.Engine.MockPipeline
  alias Neume.{MultiTrack, TrackRuntime}
  alias Neume.Voicebank.Registry

  @channels %{duration: Neume.Channels.DurationPin, pitch: Neume.Channels.PitchPin}

  # 直接构造 mock 管线的 MultiTrack 值（mock 无声库，不走
  # `MultiTrack.open/2` 的声库解析；`Neumu.ProjectStub` 同款手法）。
  defp mock_runtime(track_ids) do
    tracks =
      Map.new(track_ids, fn track_id ->
        {:ok, track} = Track.new(%{id: track_id, module: Track.Vocal})
        {track_id, track}
      end)

    {:ok, workspace} = Workspace.new(%{id: "ws-note-phonemes", tracks: tracks})

    {:ok, project} =
      Project.new(%{
        id: "project-note-phonemes",
        workspace: workspace,
        voicebank: nil,
        metadata: %{}
      })

    {:ok, session} = Coconut.new(project, channels: @channels)
    {:ok, mix_pipeline} = Neume.MixPipeline.compile(output_dir: "tmp/neume-test")

    runtimes =
      Map.new(track_ids, fn track_id ->
        {:ok, state} = MockPipeline.compile(ticks_per_frame: 10)

        {track_id,
         %TrackRuntime{
           track_id: track_id,
           voicebank: nil,
           pipeline: MockPipeline,
           pipeline_state: state,
           engine: {CoconutOi.OrchidAdapter, MockPipeline.engine_config(state, track_id)},
           channels: @channels,
           interventions: %{}
         }}
      end)

    %MultiTrack{
      session: session,
      pickle_registry: Coconut.Pickle.Track.default_registry(),
      voicebank_registry: %Registry{entries: %{}, diagnostics: []},
      tracks: runtimes,
      mix_pipeline: mix_pipeline,
      output_dir: "tmp/neume-test",
      open_opts: []
    }
  end

  test "单音符：span + 逐音素 segment ref + 预留 extras" do
    runtime = mock_runtime(["lead"])

    {:ok, runtime} =
      MultiTrack.insert_note(runtime, "lead", "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, tracks} = MultiTrack.note_phonemes(runtime)

    assert %{
             "lead" => %{
               "n1" => %{
                 span: {0, 480},
                 segments: [
                   %{segment: %{unit: "n1", member: 0, index: 0}, phoneme: "l"},
                   %{segment: %{unit: "n1", member: 0, index: 1}, phoneme: "a"}
                 ],
                 extras: %{}
               }
             }
           } = tracks
  end

  test "melisma 组：组头给全组序列，续音符只给自己的延续元音 segment" do
    runtime = mock_runtime(["lead"])

    {:ok, runtime} =
      MultiTrack.insert_note(runtime, "lead", "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    {:ok, runtime} = MultiTrack.split_note(runtime, "lead", "n1", 240, "n1b")

    assert {:ok, tracks} = MultiTrack.note_phonemes(runtime)

    # 头音符 n1 的 segments 是全组序列：自身两个音素（member 0）+ 续音
    # 成员的延续元音（member 1，index 归成员自身序列）。
    assert %{
             "n1" => %{
               segments: [
                 %{segment: %{unit: "n1", member: 0, index: 0}, phoneme: "l"},
                 %{segment: %{unit: "n1", member: 0, index: 1}, phoneme: "a"},
                 %{segment: %{unit: "n1", member: 1, index: 0}, phoneme: "a"}
               ]
             },
             "n1b" => %{
               span: {240, 480},
               segments: [%{segment: %{unit: "n1", member: 1, index: 0}, phoneme: "a"}]
             }
           } = tracks["lead"]
  end

  test "多轨：各轨独立 probe 与投影" do
    runtime = mock_runtime(["lead", "harmony"])

    {:ok, runtime} =
      MultiTrack.insert_note(runtime, "lead", "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    {:ok, runtime} =
      MultiTrack.insert_note(runtime, "harmony", "h1", :head, {0, 240}, %{
        pitch: 55,
        lyric: "mi"
      })

    assert {:ok, tracks} = MultiTrack.note_phonemes(runtime)
    assert Enum.sort(Map.keys(tracks)) == ["harmony", "lead"]

    assert %{
             "h1" => %{
               segments: [
                 %{segment: %{unit: "h1", member: 0, index: 0}, phoneme: "m"},
                 %{segment: %{unit: "h1", member: 0, index: 1}, phoneme: "i"}
               ]
             }
           } = tracks["harmony"]

    assert %{"n1" => %{segments: [_, _]}} = tracks["lead"]
  end

  test "空轨不 probe，给空映射；空工程给空 tracks" do
    runtime = mock_runtime(["lead"])
    assert {:ok, %{"lead" => %{}}} = MultiTrack.note_phonemes(runtime)

    assert {:ok, %{}} = MultiTrack.note_phonemes(mock_runtime([]))
  end

  test "probe 失败聚合为带 track_id 的 entry，不抛异常" do
    runtime = mock_runtime(["lead"])

    # 无歌词且无显式音素：mock probe loud 报错（missing_lyric）。
    {:ok, runtime} =
      MultiTrack.insert_note(runtime, "lead", "n1", :head, {0, 480}, %{pitch: 60})

    assert {:error, {:probe_failed, [entry]}} = MultiTrack.note_phonemes(runtime)
    assert %{kind: :probe, track_id: "lead", reason: {:missing_lyric, "n1"}} = entry
  end

  test "只读：不产生历史边" do
    runtime = mock_runtime(["lead"])

    {:ok, runtime} =
      MultiTrack.insert_note(runtime, "lead", "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    pin = runtime.session.history.cursor
    assert {:ok, _tracks} = MultiTrack.note_phonemes(runtime)
    assert runtime.session.history.cursor == pin
  end
end
