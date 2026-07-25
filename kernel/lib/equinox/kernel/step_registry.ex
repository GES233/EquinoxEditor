defmodule Equinox.Kernel.StepRegistry do
  @moduledoc """
  动态步骤注册中心，用于内置和第三方包注册计算步骤类型。

  每个注册项包含：
  - `:module` — 实现 `Orchid.Step`（通常经 `use Oi.Step` 声明）的模块
  - `:inputs` — 输入端口定义列表
  - `:outputs` — 输出端口定义列表
  - `:options` — 默认选项（keyword list）

  `register/2` 除显式 spec map 外，也接受导出 `__node_spec__/0` 的
  `Oi.Step` 模块，自动派生上述字段（`:options` 派生为空，可用
  `register_options/2` 补充默认值）。
  """

  use Agent

  alias Equinox.Kernel.Graph

  @type step_spec :: %{
          module: module(),
          inputs: [atom()],
          outputs: [atom()],
          options: keyword()
        }

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec register(atom(), step_spec() | module()) :: :ok
  def register(step_name, %{} = spec) do
    Agent.update(__MODULE__, &Map.put(&1, step_name, spec))
    :ok
  end

  def register(step_name, module) when is_atom(module) do
    register(step_name, spec_from_module!(module))
  end

  @spec register_options(atom(), keyword()) :: :ok | {:error, :not_registered}
  def register_options(step_name, options) when is_list(options) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state, step_name) do
        {:ok, spec} ->
          new_spec = %{spec | options: Keyword.merge(spec.options, options)}
          {:ok, Map.put(state, step_name, new_spec)}

        :error ->
          {{:error, :not_registered}, state}
      end
    end)
  end

  @spec unregister(atom()) :: :ok
  def unregister(step_name) do
    Agent.update(__MODULE__, &Map.delete(&1, step_name))
    :ok
  end

  @spec lookup(atom()) :: {:ok, step_spec()} | :error
  def lookup(step_name) do
    case Agent.get(__MODULE__, &Map.get(&1, step_name)) do
      nil -> :error
      spec -> {:ok, spec}
    end
  end

  @spec list_all() :: [{atom(), step_spec()}]
  def list_all do
    Agent.get(__MODULE__, &Map.to_list/1)
  end

  @spec create_node(atom(), keyword()) :: {:ok, Graph.Node.t()} | {:error, :not_registered}
  def create_node(step_name, overrides \\ []) do
    case lookup(step_name) do
      {:ok, spec} ->
        node = %Graph.Node{
          id: Keyword.get(overrides, :id, step_name),
          container: spec.module,
          inputs: spec.inputs,
          outputs: spec.outputs,
          options: Keyword.merge(spec.options, Keyword.drop(overrides, [:id]))
        }

        {:ok, node}

      :error ->
        {:error, :not_registered}
    end
  end

  defp spec_from_module!(module) do
    # function_exported?/3 不会触发懒加载，必须先 ensure_loaded
    unless Code.ensure_loaded?(module) and function_exported?(module, :__node_spec__, 0) do
      raise ArgumentError,
            "#{inspect(module)} 未导出 __node_spec__/0，无法派生 step_spec（请改用显式 spec map 注册）"
    end

    spec = module.__node_spec__()

    %{
      module: spec.container,
      inputs: spec.inputs,
      outputs: spec.outputs,
      options: spec.options
    }
  end
end
