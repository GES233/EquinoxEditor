defmodule Equinox.Kernel.GraphTranslator do
  @moduledoc """
  UI-specific graph payload translators should implement this behaviour.
  """

  alias Equinox.Kernel.Graph

  @callback to_graph(list(map()), list(map())) :: {:ok, Graph.t()} | {:error, term()}
end
