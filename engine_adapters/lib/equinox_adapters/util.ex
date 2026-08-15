defmodule EquinoxAdapters.Util do
  @moduledoc """
  声库 loader 的共享小件：内容戳与 character.txt 名称读取。
  """

  @doc "内容版本戳（D2：文件型声库无 semver）：sha256 前 12 hex。"
  @spec content_stamp(iodata()) :: binary()
  def content_stamp(iodata) do
    :crypto.hash(:sha256, iodata) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  @doc "读 character.txt 的 `name`（缺文件 / 缺键返回 nil）。"
  @spec character_name(Path.t()) :: binary() | nil
  def character_name(dir) do
    case File.read(Path.join(dir, "character.txt")) do
      {:ok, binary} ->
        binary
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          case String.split(line, "=", parts: 2) do
            [key, value] -> if String.downcase(key) == "name", do: String.trim(value)
            _ -> nil
          end
        end)

      {:error, _} ->
        nil
    end
  end
end
