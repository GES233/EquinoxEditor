defmodule EquinoxAdapters.DiffSinger.InferStep do
  @moduledoc """
  DiffSinger 推理 Step——窗口 words（`Packaging` 经 `:phoneme_timing`
  spec target 打包扇出）交给 Python sidecar 跑完整五段管线，wav 落盘，
  artifact `%{path, sample_rate, frames, lead_in_sec}` 上 `:audio` 端口
  （最终进 Blackboard，addr `{{track_id, window_start}, "infer|audio"}`）。
  `lead_in_sec` = wav 第 0 帧早于窗口起点的时长（preutterance/SP
  padding），播放/混音按它回挪。

  `Node.options`：

  - `:model_root`（必填）— OpenUtau 式声库目录；每个 model_root 一个
    sidecar 子进程（`Sidecar.ensure_started/2` 去重）；
  - `:seed`（可选）— 扩散采样复现用整数种子；
  - `:out_dir`（可选）— 覆盖 sidecar 默认产物目录。
  """

  use Oi.Step, name: :diffsinger_infer

  alias EquinoxAdapters.DiffSinger.Sidecar

  manifest(inputs: [:words], outputs: [audio: :audio])

  routine words, opts do
    model_root = Keyword.fetch!(opts, :model_root)
    {:ok, sidecar} = Sidecar.ensure_started(model_root, out_dir_opts(opts))

    out_path =
      Path.join(Sidecar.out_dir(sidecar), "#{words.track_id}_#{words.window_start}.wav")

    {:ok, artifact} =
      Sidecar.render(sidecar, words.words, out_path: out_path, seed: Keyword.get(opts, :seed))

    ok(artifact)
  end

  defp out_dir_opts(opts) do
    case Keyword.get(opts, :out_dir) do
      nil -> []
      out_dir -> [out_dir: out_dir]
    end
  end
end
