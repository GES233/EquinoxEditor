defmodule EquinoxDomain.Util.Object do
  @moduledoc """
  值对象。

  通过 `use EquinoxDomain.Util.Object, keys: [...]` 自动生成：

  - 结构体定义
  - `new/1`
  - `validate/1`
  - `update/2`
  """

  @callback validate(new_object :: struct()) :: {:ok, struct()} | {:error, term()}
  @optional_callbacks [validate: 1]

  defmacro __using__(opts) do
    # 和 Domain 一样，这里一般是代码编写除了问题，可以 raise
    keys = Keyword.fetch!(opts, :keys)

    quote do
      import EquinoxDomain.Helpers, only: [normalize_attrs: 2]

      @keys unquote(keys)
      defstruct @keys

      @behaviour EquinoxDomain.Util.Object

      @doc "根据属性创建新的值对象。"
      def new(attrs) do
        with {:ok, normalized} <- normalize_attrs(attrs, @keys),
             obj = struct(__MODULE__, normalized),
             {:ok, obj} <- validate(obj) do
          {:ok, obj}
        end
      end

      @doc "修改已有值对象的属性。"
      def update(obj, attrs) do
        with {:ok, normalized} <- normalize_attrs(attrs, @keys),
             new_obj = struct(obj, normalized),
             {:ok, new_obj} <- validate(new_obj) do
          {:ok, new_obj}
        end
      end

      @impl true
      def validate(obj), do: {:ok, obj}
      defoverridable validate: 1
    end
  end
end
