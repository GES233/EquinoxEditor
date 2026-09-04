defmodule Neume.Voicebank.Registry do
  @moduledoc """
  Neume 的只读多声库发现结果。

  `discover/2` 扫描给定目录本身及其直接子目录。每个有效 DiffSinger 目录
  总会产生一个 Stock entry；只有已存在且校验通过的修改 manifest 才产生
  Modified entry。发现操作绝不执行模型修改。
  """

  alias Neume.Engine.DiffSingerFp
  alias Neume.Voicebank.{DiffSinger, Entry}

  @enforce_keys [:entries, :diagnostics]
  defstruct entries: %{}, diagnostics: []

  @type diagnostic :: %{path: Path.t(), reason: term()}
  @type t :: %__MODULE__{entries: %{String.t() => Entry.t()}, diagnostics: [diagnostic()]}

  @spec configured_roots() :: [Path.t()]
  def configured_roots do
    Application.get_env(:neume, :voicebank_roots, [])
  end

  @spec discover_configured(keyword()) :: {:ok, t()}
  def discover_configured(opts \\ []) do
    discover(Keyword.get(opts, :roots, configured_roots()), Keyword.delete(opts, :roots))
  end

  @spec discover([Path.t()] | Path.t(), keyword()) :: {:ok, t()}
  def discover(roots, opts \\ []) do
    roots = if is_binary(roots), do: [roots], else: roots

    candidates =
      roots
      |> Enum.flat_map(&candidates/1)
      |> Enum.uniq()
      |> Enum.sort()

    registry =
      Enum.reduce(
        candidates,
        %__MODULE__{entries: %{}, diagnostics: []},
        &discover_candidate(&1, &2, opts)
      )

    {:ok, %{registry | diagnostics: Enum.reverse(registry.diagnostics)}}
  end

  @spec list(t()) :: [Entry.t()]
  def list(%__MODULE__{entries: entries}) do
    entries |> Map.values() |> Enum.sort_by(&{&1.name, &1.id})
  end

  @spec fetch(t(), String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def fetch(%__MODULE__{entries: entries}, id) do
    case Map.fetch(entries, id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:voicebank_not_registered, id}}
    end
  end

  @spec resolve(t(), Coconut.Project.voicebank()) :: {:ok, Entry.t()} | {:error, term()}
  def resolve(%__MODULE__{} = registry, signature) do
    case Enum.find(list(registry), &(&1.signature == signature)) do
      nil -> {:error, {:voicebank_not_registered, signature}}
      entry -> {:ok, entry}
    end
  end

  @spec prepare_modified(t(), String.t(), keyword()) :: {:ok, t(), Entry.t()} | {:error, term()}
  def prepare_modified(%__MODULE__{} = registry, stock_id, opts \\ []) do
    with {:ok, %Entry{mode: :stock, manifest: manifest}} <- fetch(registry, stock_id),
         {:ok, fp} <-
           DiffSingerFp.for_voicebank(
             manifest.root,
             Keyword.merge([voicebank_digest: manifest.digest], opts)
           ) do
      entry = Entry.modified(manifest, fp)
      {:ok, put_entry(registry, entry), entry}
    else
      {:ok, %Entry{mode: mode}} -> {:error, {:modified_requires_stock_entry, mode}}
      {:error, _} = error -> error
    end
  end

  defp candidates(root) when is_binary(root) do
    root = Path.expand(root)

    if File.dir?(root) do
      [root | root |> Path.join("*") |> Path.wildcard() |> Enum.filter(&File.dir?/1)]
    else
      [root]
    end
  end

  defp discover_candidate(path, registry, opts) do
    case DiffSinger.scan(path) do
      {:ok, manifest} ->
        registry
        |> put_entry(Entry.stock(manifest))
        |> maybe_put_fp(manifest, opts)

      {:error, reason} ->
        %{registry | diagnostics: [%{path: path, reason: reason} | registry.diagnostics]}
    end
  end

  defp maybe_put_fp(registry, manifest, _opts) do
    fp_opts = [voicebank_digest: manifest.digest, build?: false]

    case DiffSingerFp.for_voicebank(manifest.root, fp_opts) do
      {:ok, fp} ->
        put_entry(registry, Entry.modified(manifest, fp))

      {:error, {:fp_manifest_missing, _path}} ->
        registry

      {:error, reason} ->
        diagnostic = %{path: manifest.root, reason: {:invalid_modified_variant, reason}}
        %{registry | diagnostics: [diagnostic | registry.diagnostics]}
    end
  end

  defp put_entry(%__MODULE__{} = registry, %Entry{} = entry) do
    %{registry | entries: Map.put(registry.entries, entry.id, entry)}
  end
end
