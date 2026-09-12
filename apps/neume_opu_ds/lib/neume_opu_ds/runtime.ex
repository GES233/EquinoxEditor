defmodule NeumeOpuDs.Runtime do
  @moduledoc "OpenUTAU DiffSinger 声库包的 Neume runtime 适配器。"

  alias NeumeOpuDs.Pipeline

  @behaviour Neume.Runtime

  @impl true
  def compile(opts) when is_list(opts) do
    entry = Keyword.fetch!(opts, :entry)

    pipeline_opts =
      [manifest: entry.manifest, fp: entry.fp || false, track_id: Keyword.fetch!(opts, :track_id)]
      |> put_option(:output_dir, opts, :output_dir)
      |> put_option(:python, opts, :python)
      |> put_option(:backend, opts, :diffsinger_backend)
      |> put_option(:worker, opts, :diffsinger_worker)
      |> put_option(:client, opts, :diffsinger_client)
      |> put_option(:client_config, opts, :diffsinger_client_config)
      |> put_option(:speaker, opts, :speaker)
      |> put_option(:gender, opts, :gender)
      |> put_option(:velocity, opts, :velocity)
      |> put_option(:depth, opts, :depth)
      |> put_option(:steps, opts, :steps)
      |> put_option(:cache, opts, :cache)
      |> put_option(:seed, opts, :seed)
      |> put_option(:fp_dir, opts, :fp_dir)
      |> put_option(:fp_build, opts, :fp_build)
      |> put_option(:fp_python, opts, :fp_python)

    Pipeline.compile(pipeline_opts)
  end

  def compile(opts), do: {:error, {:invalid_runtime_options, opts}}

  @impl true
  defdelegate engine_config(state, track_id), to: Pipeline

  @impl true
  defdelegate voicebank_digest(state), to: Pipeline

  @impl true
  defdelegate phonology_digest(state), to: Pipeline

  @impl true
  def checked_pins(data) when is_map(data) do
    %{
      pitch: get_in(data, [:score_plan, :pitch_pins]) || %{},
      duration: get_in(data, [:score_plan, :duration_pins]) || %{}
    }
  end

  # 默认 lowering：legacy 透传，`note_tick` v2 按 snapshot 平移为绝对
  # tick 点列；worker 协议不变（不支持的 schema 由 Lower 给 tagged error）。
  @impl true
  def lower_pins(_state, snapshot, resolved, track_id),
    do: Neume.Pin.Lower.lower(resolved, snapshot, track_id)

  @impl true
  defdelegate analyze_phrases(state, snapshot, pins, globals, track_id), to: Pipeline

  @impl true
  defdelegate analyze(state, snapshot, pins, globals, track_id), to: Pipeline

  @impl true
  defdelegate phonemes(state, snapshot, track_id), to: Pipeline

  @impl true
  defdelegate render(state, snapshot, pins, globals, track_id), to: Pipeline

  @impl true
  defdelegate render_checked(state, snapshot, checked, globals, track_id), to: Pipeline

  defp put_option(target, target_key, source, source_key) do
    case Keyword.fetch(source, source_key) do
      {:ok, value} -> Keyword.put(target, target_key, value)
      :error -> target
    end
  end
end
