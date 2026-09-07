defmodule Neume.Voicebank.Registry do
  @moduledoc """
  Neume 的通用只读声库发现结果。

  registry 不理解 OpenUTAU、模型文件或变体工艺；这些职责由 entry 指向的
  `Neume.Voicebank.Provider` 实现。
  """

  alias Neume.Voicebank.Entry

  @enforce_keys [:entries, :diagnostics]
  defstruct entries: %{}, diagnostics: []

  @type diagnostic :: %{path: Path.t(), reason: term()}
  @type t :: %__MODULE__{entries: %{String.t() => Entry.t()}, diagnostics: [diagnostic()]}

  @spec new([Entry.t()], [diagnostic()]) :: t()
  def new(entries \\ [], diagnostics \\ []) do
    Enum.reduce(entries, %__MODULE__{entries: %{}, diagnostics: diagnostics}, &put_entry(&2, &1))
  end

  @spec configured_roots() :: [Path.t()]
  def configured_roots do
    Application.get_env(:neume, :voicebank_roots, [])
  end

  @spec default_provider() :: module() | nil
  def default_provider do
    Application.get_env(:neume, :voicebank_provider)
  end

  @spec discover_configured(keyword()) :: {:ok, t()} | {:error, term()}
  def discover_configured(opts \\ []) do
    discover(Keyword.get(opts, :roots, configured_roots()), Keyword.delete(opts, :roots))
  end

  @spec discover([Path.t()] | Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def discover(roots, opts \\ []) do
    provider = Keyword.get(opts, :provider, default_provider())
    dispatch(provider, :discover, [roots, Keyword.delete(opts, :provider)])
  end

  @spec entry_from_path(Path.t(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def entry_from_path(path, opts) when is_binary(path) and is_list(opts) do
    provider = Keyword.get(opts, :voicebank_provider, default_provider())
    dispatch(provider, :entry_from_path, [path, opts])
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
    with {:ok, %Entry{provider: provider} = stock} <- fetch(registry, stock_id),
         {:ok, entry} <- dispatch(provider, :prepare_modified, [stock, opts]) do
      {:ok, put_entry(registry, entry), entry}
    end
  end

  @spec put_entry(t(), Entry.t()) :: t()
  def put_entry(%__MODULE__{} = registry, %Entry{} = entry) do
    %{registry | entries: Map.put(registry.entries, entry.id, entry)}
  end

  defp dispatch(provider, function, args) when is_atom(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, function, length(args)) do
      apply(provider, function, args)
    else
      {:error, {:voicebank_provider_unavailable, provider}}
    end
  end

  defp dispatch(provider, _function, _args),
    do: {:error, {:invalid_voicebank_provider, provider}}
end
