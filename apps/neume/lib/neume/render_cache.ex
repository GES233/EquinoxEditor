defmodule Neume.RenderCache do
  @moduledoc """
  窗口级 WAV 渲染缓存。

  key 覆盖声库摘要、globals、窗内音符规范化内容与 pins —— 编辑只失效
  内容变化的窗口。缓存物只有最终 WAV 和小元数据（音素边界、ph_dur、
  lead-in），ONNX 中间张量不出 worker 进程。无淘汰策略：存放目录即
  渲染输出目录，沿用其 tmp 语义。
  """

  @version 2

  @type entry :: %{path: Path.t(), meta: map()}

  @doc "由缓存键成分算出稳定 hex key。"
  @spec key(term()) :: String.t()
  def key(parts) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(%{version: @version, parts: parts}))
    |> Base.encode16(case: :lower)
  end

  @doc "命中返回 `{:ok, entry}`，否则 `:miss`。元数据损坏视为未命中。"
  @spec fetch(Path.t(), String.t()) :: {:ok, entry()} | :miss
  def fetch(dir, key) do
    wav_path = wav_path(dir, key)
    meta_path = meta_path(dir, key)

    with true <- File.regular?(wav_path),
         {:ok, json} <- File.read(meta_path),
         {:ok, %{"version" => @version} = meta} <- Jason.decode(json) do
      {:ok, %{path: wav_path, meta: meta}}
    else
      _other -> :miss
    end
  end

  @doc "把渲染产物 WAV 复制进缓存并写入元数据。先写临时文件再 rename，多轨并行渲染同 key 时不互相截断。"
  @spec put(Path.t(), String.t(), Path.t(), map()) :: {:ok, entry()} | {:error, term()}
  def put(dir, key, source_wav, meta) when is_map(meta) do
    wav_tmp = tmp_path(dir, key, "wav")
    meta_tmp = tmp_path(dir, key, "json")
    wav_path = wav_path(dir, key)
    meta_path = meta_path(dir, key)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.cp(source_wav, wav_tmp),
         :ok <- File.write(meta_tmp, Jason.encode!(Map.put(meta, :version, @version))),
         :ok <- replace(wav_tmp, wav_path),
         :ok <- replace(meta_tmp, meta_path) do
      {:ok, %{path: wav_path, meta: stringify(meta)}}
    end
  end

  # Windows 上 rename 不覆盖已存在目标：先删后改，读取侧把短暂缺失当 miss。
  # 目标不存在时 File.rm 返回 :enoent，属正常路径。
  defp replace(tmp, target) do
    _ = File.rm(target)
    File.rename(tmp, target)
  end

  defp tmp_path(dir, key, ext) do
    Path.join(dir, "#{key}.#{System.unique_integer([:positive])}.#{ext}.tmp")
  end

  defp wav_path(dir, key), do: Path.join(dir, "#{key}.wav")
  defp meta_path(dir, key), do: Path.join(dir, "#{key}.json")

  # 与 fetch 解码后的形态对齐（字符串键 + version），调用侧无需分辨来源。
  defp stringify(meta) do
    meta |> Jason.encode!() |> Jason.decode!()
  end
end
