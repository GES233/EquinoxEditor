defmodule Equinox.Kernel.Plugin do
  @moduledoc """
  负责将 Orchid 的自定义 Hooks/Operons 集成到 Equinox 渲染器中。

  第三方包可实现此 behaviour 并在 Configurator 中注册。
  """

  @type orchid_tuple :: {Orchid.Recipe.t(), orchid_opts :: keyword()}

  @callback apply_plugin(orchid_tuple(), plugin_context :: term()) :: orchid_tuple()
end
