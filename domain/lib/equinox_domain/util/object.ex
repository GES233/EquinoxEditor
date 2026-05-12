defmodule EquinoxDomain.Util.Object do
  @moduledoc """
  值对象。

  通过 `use EquinoxDomain.Util.Object, keys: [...]` 自动生成：

  - 结构体定义
  - `new/1`
  - `update/2`
  """

  defmacro __using__(opts) do
    # 和 Domain 一样，这里一般是代码编写除了问题，可以 raise
    keys = Keyword.fetch!(opts, :keys)

    quote do
      import EquinoxDomain.Helpers, only: [normalize_attrs: 2]

      @keys unquote(keys)
      defstruct @keys

      @doc """
      根据属性创建新的值对象。

      `attrs` 可以是 map 或 keyword list，键可以使用原子或字符串。
      """
      def new(attrs) do
        with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
          struct(__MODULE__, normalized)
        end
      end

      @doc """
      修改已有值对象的属性。

      `attrs` 格式同 `new/1`。
      """
      def update(obj, attrs) do
        with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
          struct(obj, normalized)
        end
      end
    end
  end
end
