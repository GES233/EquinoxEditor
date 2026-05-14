defmodule EquinoxDomain.Util.Model do
  @moduledoc """
  领域模型。

  通过 `use EquinoxDomain.Util.Model, keys: [...], id_prefix: "xxx"` 自动生成：

  - 结构体定义
  - `new/1`
  - `update/2`

  以及加载必要的辅助函数（属性标准化、ID 生成）。
  """

  @callback validate(model :: struct()) :: {:ok, struct()} | {:error, term()}
  @optional_callbacks [validate: 1]

  defmacro __using__(opts) do
    # 这里一般是代码编写除了问题，可以 raise
    keys = Keyword.fetch!(opts, :keys)
    id_prefix = Keyword.get(opts, :id_prefix)

    quote do
      import EquinoxDomain.Helpers, only: [normalize_attrs: 2]
      import EquinoxDomain.Util.ID, only: [generate_id: 1]

      @behaviour EquinoxDomain.Util.Model

      @keys unquote(keys)
      defstruct @keys

      # ---- 自动生成的构造/修改函数 ----

      @doc """
      根据属性创建新的结构体。

      `attrs` 可以是 map 或 keyword list，键可以使用原子或字符串。
      如果未提供 `:id`，会自动调用 `generate_id/0` 生成 ID。
      """
      def new(attrs) do
        with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
          {id, attrs} = Map.pop(normalized, :id, generate_id(unquote(id_prefix)))
          struct(__MODULE__, Map.put(attrs, :id, id))
          |> validate()
        end
      end

      @doc """
      修改已有结构体的属性（不允许修改 `:id`）。

      `attrs` 格式同 `new/1`。
      """
      def update(model, attrs) do
        with {:ok, normalized} <- normalize_attrs(attrs, @keys),
             :ok <- if(Map.has_key?(normalized, :id), do: {:error, :id_immutable}, else: :ok),
             new_model = struct(model, attrs),
             {:ok, new_model} <- validate(new_model) do
          {:ok, new_model}
        end
      end

      @impl true
      def validate(model), do: {:ok, model}
      defoverridable validate: 1
    end
  end
end
