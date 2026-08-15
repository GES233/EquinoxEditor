defmodule Equinox.Kernel.Configurator do
  @moduledoc """
  不可变的渲染通道配置。
  在调度边界创建一次，向下传递到 Engine/Worker 和插件链。

  channel spec 的**单一来源**是 `Equinox.Kernel.EngineAdapter` 实现：
  `new(engine: {adapter, config})` 内部展开为 `adapter.channels(config)`。
  `:channels` 手工注入保留为兼容 / 实验通道；同 key 冲突时 Adapter
  派生者优先（单一来源纪律）。

  `global_rules` 同纪律从 Adapter 派生（`adapter.globals(config)`），是
  Runner check 阶段 globals 门控的回落规则（per-track 规则挂在 dispatch
  的 `track_global_rules`）；无 engine 时为 nil（不做门控）。
  """

  alias Equinox.Kernel.Graph
  alias EquinoxDomain.Command.RenderRequest

  @typedoc "通道规格：`projection` 以窗口 RenderRequest + 单条 patch 求该 patch 锚区的新鲜投影（canonical term，作 `Tamale.Patch.resolve/2` 的 digest 输入）；`target` 为 PortRef 直取，或 payload → [{PortRef, value}] 的一元 fan-out 函数。"
  @type channel_spec :: %{
          projection: (RenderRequest.t(), Coconut.Edit.Patch.t() ->
                         {:ok, term()} | {:error, term()}),
          target: Graph.PortRef.t() | (term() -> [{Graph.PortRef.t(), term()}])
        }

  @type t :: %__MODULE__{
          plugins: [{module(), context :: any()}],
          orchid_baggage: map(),
          orchid_opts: keyword(),
          concurrency: pos_integer(),
          timeout: timeout(),
          channels: %{atom() => channel_spec()},
          global_rules: nil | %{atom() => {:range, term(), term()} | {:enum, [term()]}},
          engine: nil | {module(), term()}
        }

  defstruct plugins: [],
            orchid_baggage: %{},
            orchid_opts: [],
            concurrency: System.schedulers_online(),
            timeout: :infinity,
            channels: %{},
            global_rules: nil,
            engine: nil

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    engine = Keyword.get(opts, :engine)

    %__MODULE__{
      plugins: Keyword.get(opts, :plugins, []),
      orchid_baggage: opts |> Keyword.get(:orchid_baggage, []) |> Enum.into(%{}),
      orchid_opts: Keyword.get(opts, :orchid_opts, []),
      concurrency: Keyword.get(opts, :concurrency, System.schedulers_online()),
      timeout: Keyword.get(opts, :timeout, :infinity),
      channels: derive_channels(engine, opts |> Keyword.get(:channels, %{}) |> Map.new()),
      global_rules: derive_global_rules(engine),
      engine: engine
    }
  end

  # Adapter 派生（单一来源）：同 key 冲突时派生者优先于手工注入
  defp derive_channels({adapter, config}, manual) when is_atom(adapter),
    do: Map.merge(manual, adapter.channels(config))

  defp derive_channels(_no_engine, manual), do: manual

  # globals 校验规则同纪律派生；无 engine → nil（Runner 不做 globals 门控）
  defp derive_global_rules({adapter, config}) when is_atom(adapter),
    do: adapter.globals(config)

  defp derive_global_rules(_no_engine), do: nil

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

  @doc "将模块式插件链翻译为 Oi 的 `orchid_adapters`（1-arity 函数列表，顺序保持）。"
  @spec as_orchid_adapters(t()) :: [
          ({Orchid.Recipe.t(), keyword()} -> {Orchid.Recipe.t(), keyword()})
        ]
  def as_orchid_adapters(%__MODULE__{plugins: plugins}) do
    Enum.map(plugins, fn
      {plugin_module, context} when is_atom(plugin_module) ->
        fn orchid_tuple -> plugin_module.apply_plugin(orchid_tuple, context) end

      plugin_module when is_atom(plugin_module) ->
        fn orchid_tuple -> plugin_module.apply_plugin(orchid_tuple, nil) end
    end)
  end
end
