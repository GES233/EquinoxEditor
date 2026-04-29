defmodule EquinoxDomain.Util.Model do
  @moduledoc """
  领域模型。

  通过 `use EquinoxDomain.Util.Model, keys: [...], id_prefix: "xxx"` 自动生成：

  - 结构体定义
  - `new/1`
  - `update/2`

  以及加载必要的辅助函数（属性标准化、ID 生成）。
  """

  defmacro __using__(opts) do
    keys = Keyword.fetch!(opts, :keys)
    id_prefix = Keyword.get(opts, :id_prefix)

    quote do
      import EquinoxDomain.Helpers, only: [generate_id: 1, normalize_attrs: 2]

      @keys unquote(keys)
      defstruct @keys

      # ---- 自动生成的构造/修改函数 ----

      @doc """
      根据属性创建新的结构体。

      `attrs` 可以是 map 或 keyword list，键可以使用原子或字符串。
      如果未提供 `:id`，会自动调用 `generate_id/0` 生成 ID。
      """
      def new(attrs) do
        attrs
        |> normalize_attrs(@keys)
        |> Map.pop(:id, generate_id(unquote(id_prefix)))
        |> then(fn {id, attrs} -> struct!(__MODULE__, Map.merge(attrs, %{id: id})) end)
      end

      @doc """
      修改已有结构体的属性（不允许修改 `:id`）。

      `attrs` 格式同 `new/1`。
      """
      def update(model, attrs) do
        {id, attrs} =
          attrs
          |> normalize_attrs(@keys)
          |> Map.pop(:id)

        with nil <- id do
          {:ok, struct!(model, attrs)}
        else
          _ -> {:error, :id_immutable}
        end
      end
    end
  end
end
