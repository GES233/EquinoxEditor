defmodule Neumu.CheckReport do
  @moduledoc """
  check/render 失败原因的 plain-data 投影。

  `Neume` 的 check 冲突 entry 携带 `%Coconut.Edit.Patch{}` struct 等运行时
  领域值，不能直接跨 facade 边界；本模块把它们投影为可序列化 plain
  data（patch 只留 `patch_id`/`channel`/`note_id`），供 `Neumu.check/1`
  与 `Neumu.list_render_jobs/1` 使用。
  """

  alias Coconut.Edit.Patch

  @doc "投影 check 失败条目列表；`{:check_failed, entries}` 之外的原因原样净化。"
  @spec project_error(term()) :: term()
  def project_error({:check_failed, entries}) when is_list(entries),
    do: {:check_failed, project_entries(entries)}

  def project_error(other), do: sanitize(other)

  @doc "投影 check 冲突/模型/门禁条目列表为 plain data。"
  @spec project_entries([term()]) :: [term()]
  def project_entries(entries) when is_list(entries), do: Enum.map(entries, &project_entry/1)

  # 携 patch struct 的条目（身份/静态冲突）：patch 降为 id + note 引用。
  defp project_entry(%{patch: %Patch{} = patch} = entry) do
    entry
    |> Map.drop([:patch])
    |> Map.put(:patch_id, patch.id)
    |> Map.put(:note_id, anchor_note_id(patch))
    |> Map.put(:channel, patch.channel)
    |> sanitize()
  end

  defp project_entry(entry), do: sanitize(entry)

  defp anchor_note_id(%Patch{anchor: %Tamale.Anchor.Ordinal{refs: [note_id | _]}}), do: note_id
  defp anchor_note_id(_patch), do: nil

  # 深度净化：运行时对象（struct/pid/function/reference/port）一律降为
  # inspect 字符串；key 保持原样（facade 投影只产 atom/binary key）。
  defp sanitize(term) when is_pid(term) or is_function(term) or is_reference(term),
    do: inspect(term)

  defp sanitize(%_{} = struct), do: inspect(struct)

  defp sanitize(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, sanitize(v)} end)

  defp sanitize(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&sanitize/1) |> List.to_tuple()

  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  defp sanitize(term), do: term
end
