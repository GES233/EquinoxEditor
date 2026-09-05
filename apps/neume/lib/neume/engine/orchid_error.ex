defmodule Neume.Engine.OrchidError do
  @moduledoc """
  Oi/Orchid 执行错误在 Neume 边界的收敛。

  Oi 执行失败返回 `{:orchid_error, recipe, %Orchid.Error{}}`；其 `context`
  携带整个调度上下文（recipe、params、乐谱快照），inspect 后可达数百
  KB——下游（check 条目、渲染任务 error、facade 投影、UI 展示）只需要
  机器可判的内层原因。本模块在条目/错误构造处剥掉 `context`，留下
  `%{reason, step_id, kind}`；`reason` 原样保留（机器可判契约不变）。
  """

  @doc """
  收敛执行错误：`{:orchid_error, recipe, %Orchid.Error{}}` 降为等长三元组
  `{:orchid_error, recipe, %{reason, step_id, kind}}`；其余 term 原样返回
  （幂等，收敛过的值再过一遍不变）。
  """
  @spec slim(term()) :: term()
  def slim({:orchid_error, recipe, %Orchid.Error{} = error}) do
    {:orchid_error, recipe,
     %{reason: error.reason, step_id: step_id(error.step_id), kind: error.kind}}
  end

  def slim(other), do: other

  # Step.ID 是 MapSet 元组等富结构；标量原样保留，富结构降为 inspect 摘要。
  defp step_id(id) when is_binary(id) or is_atom(id) or is_nil(id), do: id
  defp step_id(id), do: inspect(id)
end
