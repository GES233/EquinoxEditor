defmodule Equinox.Kernel.Configurator do
  @moduledoc """
  不可变的渲染通道配置。
  在调度边界创建一次，向下传递到 Engine/Worker 和插件链。
  """

  @type t :: %__MODULE__{
          plugins: [{module(), context :: any()}],
          orchid_baggage: map(),
          orchid_opts: keyword(),
          concurrency: pos_integer(),
          timeout: timeout()
        }

  defstruct plugins: [],
            orchid_baggage: %{},
            orchid_opts: [],
            concurrency: System.schedulers_online(),
            timeout: :infinity

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      plugins: Keyword.get(opts, :plugins, []),
      orchid_baggage: opts |> Keyword.get(:orchid_baggage, []) |> Enum.into(%{}),
      orchid_opts: Keyword.get(opts, :orchid_opts, []),
      concurrency: Keyword.get(opts, :concurrency, System.schedulers_online()),
      timeout: Keyword.get(opts, :timeout, :infinity)
    }
  end

  @spec apply_plugins(t(), {Orchid.Recipe.t(), keyword()}) ::
          {Orchid.Recipe.t(), keyword()}
  def apply_plugins(%__MODULE__{plugins: plugins}, orchid_tuple) do
    Enum.reduce(plugins, orchid_tuple, fn plugin, acc ->
      case plugin do
        {plugin_module, context} when is_atom(plugin_module) ->
          plugin_module.apply_plugin(acc, context)

        plugin_module when is_atom(plugin_module) ->
          plugin_module.apply_plugin(acc, nil)
      end
    end)
  end
end
