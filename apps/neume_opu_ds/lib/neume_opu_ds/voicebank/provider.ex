defmodule NeumeOpuDs.Voicebank.Provider do
  @moduledoc "OpenUTAU DiffSinger 声库的发现、变体构建与 runtime 绑定。"

  alias Neume.Voicebank.{Entry, Registry}
  alias NeumeOpuDs.{Fp, Runtime}
  alias NeumeOpuDs.Voicebank.Manifest

  @behaviour Neume.Voicebank.Provider

  @impl true
  def discover(roots, opts \\ []) do
    roots = if is_binary(roots), do: [roots], else: roots

    candidates =
      roots
      |> Enum.flat_map(&candidates/1)
      |> Enum.uniq()
      |> Enum.sort()

    registry =
      Enum.reduce(candidates, Registry.new(), &discover_candidate(&1, &2, opts))

    {:ok, %{registry | diagnostics: Enum.reverse(registry.diagnostics)}}
  end

  @impl true
  def entry_from_path(path, opts) do
    case Keyword.fetch(opts, :voicebank_mode) do
      {:ok, :stock} ->
        with {:ok, manifest} <- Manifest.scan(path), do: {:ok, stock(manifest)}

      {:ok, :modified} ->
        with {:ok, manifest} <- Manifest.scan(path),
             {:ok, fp} <- build_fp(manifest, opts) do
          {:ok, modified(manifest, fp)}
        end

      {:ok, mode} ->
        {:error, {:invalid_voicebank_mode, mode}}

      :error ->
        {:error, :voicebank_mode_required}
    end
  end

  @impl true
  def prepare_modified(%Entry{provider: __MODULE__, mode: :stock, manifest: manifest}, opts) do
    with {:ok, fp} <-
           Fp.for_voicebank(
             manifest.root,
             Keyword.merge([voicebank_digest: manifest.digest], opts)
           ) do
      {:ok, modified(manifest, fp)}
    end
  end

  def prepare_modified(%Entry{provider: __MODULE__, mode: mode}, _opts),
    do: {:error, {:modified_requires_stock_entry, mode}}

  @spec stock(Manifest.t()) :: Entry.t()
  def stock(%Manifest{} = manifest) do
    signature = %{
      name: "#{manifest.name} (Stock)",
      engine: :diffsinger_stock,
      digest: manifest.digest
    }

    %Entry{
      id: Entry.id(signature),
      name: signature.name,
      provider: __MODULE__,
      runtime: Runtime,
      mode: :stock,
      manifest: manifest,
      fp: nil,
      signature: signature
    }
  end

  @spec modified(Manifest.t(), Fp.t()) :: Entry.t()
  def modified(%Manifest{} = manifest, %{manifest_digest: fp_digest, noise_version: version} = fp) do
    digest =
      :crypto.hash(
        :sha256,
        [
          "neume/diffsinger-modified/1\0",
          manifest.digest,
          "\0",
          fp_digest,
          "\0",
          to_string(version)
        ]
      )
      |> Base.encode16(case: :lower)

    signature = %{
      name: "#{manifest.name} (Modified)",
      engine: :diffsinger_modified,
      digest: digest
    }

    %Entry{
      id: Entry.id(signature),
      name: signature.name,
      provider: __MODULE__,
      runtime: Runtime,
      mode: :modified,
      manifest: manifest,
      fp: fp,
      signature: signature
    }
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
    case Manifest.scan(path) do
      {:ok, manifest} ->
        registry
        |> Registry.put_entry(stock(manifest))
        |> maybe_put_fp(manifest, opts)

      {:error, reason} ->
        %{registry | diagnostics: [%{path: path, reason: reason} | registry.diagnostics]}
    end
  end

  defp maybe_put_fp(registry, manifest, _opts) do
    fp_opts = [voicebank_digest: manifest.digest, build?: false]

    case Fp.for_voicebank(manifest.root, fp_opts) do
      {:ok, fp} ->
        Registry.put_entry(registry, modified(manifest, fp))

      {:error, {:fp_manifest_missing, _path}} ->
        registry

      {:error, reason} ->
        diagnostic = %{path: manifest.root, reason: {:invalid_modified_variant, reason}}
        %{registry | diagnostics: [diagnostic | registry.diagnostics]}
    end
  end

  defp build_fp(manifest, opts) do
    fp_opts = [
      voicebank_digest: manifest.digest,
      build?: Keyword.get(opts, :fp_build, true),
      python: Keyword.get(opts, :fp_python, ["python"])
    ]

    fp_opts = if opts[:fp_dir], do: Keyword.put(fp_opts, :dir, opts[:fp_dir]), else: fp_opts
    Fp.for_voicebank(manifest.root, fp_opts)
  end
end
