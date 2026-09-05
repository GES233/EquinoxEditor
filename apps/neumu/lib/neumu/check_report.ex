defmodule Neumu.CheckReport do
  @moduledoc """
  check/render 失败原因的 plain-data 投影。

  `Neume` 的 check 冲突 entry 携带 `%Coconut.Edit.Patch{}` struct 等运行时
  领域值，不能直接跨 facade 边界；本模块把它们投影为可序列化 plain
  data（patch 只留 `patch_id`/`channel`/`note_id`，`span` 等结构化字段
  降为 JSON-safe 的 list），供 `Neumu.check/1` 与
  `Neumu.list_render_jobs/1` 使用。

  `reason` 字段保持结构化 tagged term：Elixir 调用方需要机器可判，
  UI 只展示；壳层推到浏览器前的末端转换（tuple→list 等）归壳层，
  见 `docs/facade-protocol.md`。
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

  # 冲突条目的结构化字段 JSON-safe：tuple 递归降为位置即标签的 list
  # （`span`/`phrase_id` 等）；`reason` 保持结构化 tagged term（Elixir 侧
  # 机器可判，UI 只展示——末端转换归壳层，见 docs/facade-protocol.md）。
  defp project_entry(%{patch: %Patch{} = patch} = entry) do
    entry
    |> Map.drop([:patch])
    |> Map.put(:patch_id, patch.id)
    |> Map.put(:note_id, anchor_note_id(patch))
    |> Map.put(:channel, patch.channel)
    |> sanitize()
    |> deep_lists()
  end

  defp project_entry(entry), do: entry |> sanitize() |> deep_lists()

  defp anchor_note_id(%Patch{anchor: %Tamale.Anchor.Ordinal{refs: [note_id | _]}}), do: note_id
  defp anchor_note_id(_patch), do: nil

  # 结构化字段的 JSON-safe 化：tuple 递归降为 list；`:reason` 键下的值例外，
  # 保持结构化 tagged term（Elixir 机器可判），末端转换归壳层。
  defp deep_lists(%{reason: _reason} = entry) when is_map(entry) do
    Map.new(entry, fn
      {:reason, reason} -> {:reason, reason}
      {key, value} -> {key, deep_lists(value)}
    end)
  end

  defp deep_lists(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, deep_lists(value)} end)

  defp deep_lists(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&deep_lists/1)

  defp deep_lists(list) when is_list(list), do: Enum.map(list, &deep_lists/1)
  defp deep_lists(term), do: term

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
