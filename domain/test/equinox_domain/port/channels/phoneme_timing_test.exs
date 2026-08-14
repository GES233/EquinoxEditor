defmodule EquinoxDomain.Port.Channels.PhonemeTimingTest do
  use ExUnit.Case, async: true

  import EquinoxDomain.TestFactory

  alias EquinoxDomain.Port.Channels.PhonemeTiming

  defp setup do
    {project, track_id} = project_with_track()
    project = insert_notes(project, track_id, [{"n1", 0, 480, %{pitch: 60, lyric: "あ"}}])
    {:ok, track} = EquinoxDomain.Score.Project.fetch_track(project, track_id)
    {project, track_id, track}
  end

  defp shell_patch(track_id, anchor) do
    %Coconut.Edit.Patch{
      id: nil,
      track_id: track_id,
      anchor: anchor,
      patch: nil,
      channel: :phoneme_timing
    }
  end

  test "channel/0 与 target/0" do
    assert PhonemeTiming.channel() == :phoneme_timing
    assert PhonemeTiming.target() == {:port, :synth, :phoneme_timing}
  end

  test "projection/2：Ordinal 锚产出 canonical base（digest 可接受）" do
    {project, track_id, track} = setup()

    patch =
      shell_patch(track_id, %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: track.space.version})

    assert {:ok, base} = PhonemeTiming.projection(project.workspace, patch)

    # base 是 plain map：note canonical + span 整数对
    assert %{"note" => %{"lyric" => "あ"}, "span" => [0, 480]} = base

    # canonical 纪律：Tamale.Digest 直接可算（无 float / struct / tuple）
    assert {:ok, digest} = Tamale.Digest.digest(base)
    assert is_binary(digest)
  end

  test "projection/2：Relative 锚取 ref 音符" do
    {project, track_id, track} = setup()

    patch =
      shell_patch(track_id, %Tamale.Anchor.Relative{
        ref: "n1",
        from_offset: 0,
        to_offset: 240,
        at_version: track.space.version
      })

    assert {:ok, %{"span" => [0, 480]}} = PhonemeTiming.projection(project.workspace, patch)
  end

  test "projection/2 错误路径" do
    {project, track_id, track} = setup()

    # Metric 锚不支持
    metric = shell_patch(track_id, %Tamale.Anchor.Metric{coord: :tick, from: 0, to: 480})
    assert {:error, :unsupported_anchor} = PhonemeTiming.projection(project.workspace, metric)

    # 音符不存在
    missing =
      shell_patch(track_id, %Tamale.Anchor.Ordinal{refs: ["n9"], at_version: track.space.version})

    assert {:error, {:note_not_found, "n9"}} =
             PhonemeTiming.projection(project.workspace, missing)
  end

  test "canonicalize/1：float → 十进制字符串，atom → 字符串，tuple → list" do
    assert {:ok, canonical} =
             PhonemeTiming.canonicalize(%{
               float: 0.5,
               atom: :vowel,
               tuple: {1, 2},
               list: [1, "a", nil, true]
             })

    assert canonical == %{
             "atom" => "vowel",
             "float" => "0.5",
             "list" => [1, "a", nil, true],
             "tuple" => [1, 2]
           }

    assert {:ok, _} = Tamale.Digest.digest(canonical)
    assert {:error, {:non_canonical, _}} = PhonemeTiming.canonicalize(%{s: %URI{}})
  end
end
