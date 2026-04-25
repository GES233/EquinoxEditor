defmodule EquinoxDomain.Model do
  @moduledoc """
  通过 `use EquinoxDomain.Model, keys: [...], id_prefix: "xxx"` 自动生成：

  - 结构体定义
  - `new/1`
  - `update/2`

  以及必要的辅助函数（属性标准化、ID 生成）。
  """

  defmacro __using__(opts) do
    keys = Keyword.fetch!(opts, :keys)
    id_prefix = Keyword.get(opts, :id_prefix)

    quote do
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
        |> Map.pop(:id, generate_id())
        |> then(fn {id, attrs} -> struct!(__MODULE__, Map.merge(attrs, %{id: id})) end)
      end

      @doc """
      修改已有结构体的属性（不能修改 `:id`）。
      `attrs` 格式同 `new/1`。
      """
      def update(note, attrs) do
        {_id, attrs} =
          attrs
          |> normalize_attrs(@keys)
          |> Map.pop(:id)

        Map.merge(note, attrs)
      end

      # ---- 私有辅助函数 ----

      defp normalize_attrs(map_or_kw, fields) do
        allowed_set =
          MapSet.new(fields, fn
            {k, _} when is_atom(k) ->
              Atom.to_string(k)

            k when is_atom(k) ->
              Atom.to_string(k)

            other ->
              raise ArgumentError, "field must be atom or {atom, default}, got: #{inspect(other)}"
          end)

        for {k, v} <- map_or_kw,
            key_str = if(is_atom(k), do: Atom.to_string(k), else: k),
            key_str in allowed_set,
            into: %{} do
          {String.to_existing_atom(key_str), v}
        end
      end

      unquote(
        if id_prefix do
          quote do
            defp generate_id do
              unquote(id_prefix) <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
            end
          end
        else
          quote do
            defp generate_id do
              Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
            end
          end
        end
      )
    end
  end
end
