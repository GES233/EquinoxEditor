defmodule EquinoxDomain.Windowing.Window do
  @moduledoc """
  渲染窗口——Windowing 的瞬态投影产物（左闭右开 `[start_tick, end_tick)`）。

  Window 是从音符（与外部 content span）现场计算的纯数据，
  永不持久化、不作任何 patch 的锚；每次编辑后由
  `EquinoxDomain.Windowing.slice/2` 全量重建。

  `note_ids` 为窗口覆盖的音符 id 列表（按起音序，可能与 `extra_spans`
  撑出的窗口相交为空——纯 scope 窗口允许 `note_ids == []`）。
  """

  import Coconut.Util.Helpers, only: [normalize_attrs: 2, strictly_normalize_attrs: 2]

  @type t :: %__MODULE__{
          start_tick: Coconut.Score.Tick.numeric_tick(),
          end_tick: Coconut.Score.Tick.numeric_tick(),
          note_ids: [Coconut.Score.Note.note_id()]
        }

  @keys [:start_tick, :end_tick, note_ids: []]
  defstruct @keys

  @doc "构造窗口；`start_tick`/`end_tick` 必填且须满足 `0 <= start_tick < end_tick`。"
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
      struct(__MODULE__, normalized) |> validate()
    end
  end

  @doc "更新窗口字段（`note_ids` 等），重新校验。"
  @spec update(t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def update(%__MODULE__{} = window, attrs) do
    with {:ok, normalized} <- strictly_normalize_attrs(attrs, @keys) do
      struct(window, normalized) |> validate()
    end
  end

  @doc "窗口合法性：tick 为非负整数且 `start_tick < end_tick`，`note_ids` 为列表。"
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{start_tick: s, end_tick: e, note_ids: ids} = window) do
    cond do
      not (is_integer(s) and is_integer(e) and s >= 0 and e > s) ->
        {:error, {:invalid_window_span, {s, e}}}

      not is_list(ids) ->
        {:error, {:invalid_note_ids, ids}}

      true ->
        {:ok, window}
    end
  end
end
