defmodule Neume.RenderCacheTest do
  use ExUnit.Case, async: true

  alias Neume.RenderCache
  alias Neume.Wav

  defp parts(overrides \\ %{}) do
    Map.merge(
      %{
        voicebank_digest: "vb-digest",
        globals: %{"speaker" => "Normal", "steps" => 2},
        notes: [["n1", "啦", "zh", nil, 60, 0, 480]],
        pins: %{pitch: %{}, duration: %{}}
      },
      overrides
    )
  end

  test "相同成分得相同 key，任一成分变化改变 key" do
    assert RenderCache.key(parts()) == RenderCache.key(parts())
    assert RenderCache.key(parts()) != RenderCache.key(parts(%{globals: %{"steps" => 8}}))

    assert RenderCache.key(parts()) !=
             RenderCache.key(parts(%{notes: [["n1", "啦", "zh", nil, 61, 0, 480]]}))

    assert RenderCache.key(parts()) != RenderCache.key(parts(%{voicebank_digest: "other"}))
  end

  @tag tmp_dir: true
  test "put 后 fetch 命中，未知 key 未命中", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.wav")
    assert :ok = Wav.write(source, <<1::little-16, 2::little-16>>, 44_100)

    key = RenderCache.key(parts())

    assert :miss = RenderCache.fetch(tmp_dir, key)

    assert {:ok, entry} =
             RenderCache.put(tmp_dir, key, source, %{
               "frames" => 86,
               "lead_in_sec" => 0.5,
               "sample_rate" => 44_100,
               "ph_dur" => [43, 43]
             })

    assert {:ok, fetched} = RenderCache.fetch(tmp_dir, key)
    assert fetched.path == entry.path
    assert fetched.meta["frames"] == 86
    assert fetched.meta["ph_dur"] == [43, 43]
    assert {:ok, clip} = Wav.read(fetched.path)
    assert clip.samples == <<1::little-16, 2::little-16>>
  end

  @tag tmp_dir: true
  test "元数据损坏视为未命中", %{tmp_dir: tmp_dir} do
    key = RenderCache.key(parts())
    File.write!(Path.join(tmp_dir, "#{key}.wav"), "RIFF")
    File.write!(Path.join(tmp_dir, "#{key}.json"), "not json")

    assert :miss = RenderCache.fetch(tmp_dir, key)
  end
end
