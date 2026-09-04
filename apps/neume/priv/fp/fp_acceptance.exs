# Asaritsu Pure-FP 真机验收：
#   cd apps/neume
#   mix run priv/fp/fp_acceptance.exs

voicebank = System.get_env("DS_VOICEBANK") || "E:/ProgramAssets/OpenUTAUSingers/Asaritsu"
worker_python = [System.get_env("DS_PYTHON") || "D:/CodeRepo/Qy/coconut/.venv/Scripts/python.exe"]
fp_python = [System.get_env("FP_PYTHON") || "python"]
root = Path.join(File.cwd!(), "tmp/fp_acceptance")
File.rm_rf!(root)
File.mkdir_p!(root)

render = fn mode, seed, name ->
  {:ok, editor} =
    Neume.Editor.new(
      voicebank_path: voicebank,
      voicebank_mode: if(mode, do: :modified, else: :stock),
      python: worker_python,
      fp_python: fp_python,
      seed: seed,
      cache: false,
      steps: 4,
      output_dir: Path.join(root, name)
    )

  {:ok, editor} =
    Neume.Editor.insert_note(editor, "n1", :head, {0, 960}, %{pitch: 64, lyric: "啊"})

  {:ok, _editor, artifact} = Neume.Editor.render(editor)
  bytes = File.read!(artifact.path)

  %{
    bytes: bytes,
    hash: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
    path: artifact.path
  }
end

fp0a = render.(:default, 0, "fp0a")
fp0b = render.(:default, 0, "fp0b")
fp1 = render.(:default, 1, "fp1")
stock = render.(false, 0, "stock")

true = fp0a.bytes == fp0b.bytes
false = fp0a.bytes == fp1.bytes

stats = fn bytes ->
  <<_header::binary-size(44), pcm::binary>> = bytes
  samples = for <<sample::little-signed-16 <- pcm>>, do: sample / 32768.0
  mean = Enum.sum(samples) / length(samples)
  variance = Enum.sum(Enum.map(samples, &:math.pow(&1 - mean, 2))) / length(samples)
  %{mean: mean, std: :math.sqrt(variance)}
end

fp_stats = stats.(fp1.bytes)
stock_stats = stats.(stock.bytes)
relative = fn a, b -> abs(a - b) / max(abs(b), 1.0e-6) end
std_relative_delta = relative.(fp_stats.std, stock_stats.std)

# 1 秒短 take 的 stock RNG 方差明显高于 coconut_intervention 的 35 拍样本；
# 这里用 2× RMS 包络（相对差 < 50%）防止结构性语义破坏，同时输出精确值。
true = std_relative_delta < 0.50

IO.inspect(%{
  same_seed_identical: fp0a.hash == fp0b.hash,
  different_seed_differs: fp0a.hash != fp1.hash,
  fp_seed0_sha256: fp0a.hash,
  fp_seed1_sha256: fp1.hash,
  stock_sha256: stock.hash,
  semantic_sample_seed: 1,
  std_relative_delta: std_relative_delta,
  fp_stats: fp_stats,
  stock_stats: stock_stats
})
