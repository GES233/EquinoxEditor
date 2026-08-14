defmodule EquinoxDomain.Score.Track do
  @moduledoc """
  轨道查询门面——对 `Project` / `Coconut.Edit.Workspace` 的无状态只读封装。

  coconut 时代轨道真相在 `Coconut.Edit.Track`（Space + spans 侧表 + patches），
  写路径由 kernel 经 `Coconut.Edit.History` + Operations/Command 完成；
  本模块只提供 equinox 常用的三个查询：

  - `notes/2` — 轨道全部音符（带 span）
  - `note/3` — 单个音符（带 span）
  - `slice/3` — 分窗投影（代理 `EquinoxDomain.Windowing`）
  """

  alias EquinoxDomain.Score.Project
  alias EquinoxDomain.Windowing

  @typedoc "带时序的音符视图项：`{note_id, note, {start_tick, end_tick}}`。"
  @type note_entry :: Windowing.item()

  @doc "轨道全部音符视图（按 `{start, id}` 排序）。"
  @spec notes(Project.t(), Coconut.Edit.Track.track_id()) ::
          {:ok, [note_entry()]} | {:error, term()}
  def notes(%Project{} = project, track_id), do: Project.view(project, track_id)

  @doc "按 id 取单个音符（带 span）；不存在报 `{:error, {:note_not_found, id}}`。"
  @spec note(Project.t(), Coconut.Edit.Track.track_id(), Coconut.Score.Note.note_id()) ::
          {:ok, note_entry()} | {:error, term()}
  def note(%Project{} = project, track_id, note_id) do
    with {:ok, entries} <- notes(project, track_id) do
      case Enum.find(entries, fn {id, _note, _span} -> id == note_id end) do
        nil -> {:error, {:note_not_found, note_id}}
        entry -> {:ok, entry}
      end
    end
  end

  @doc """
  分窗投影：轨道音符视图 → `{:ok, [Windowing.Window.t()]}`。

  `opts` 透传 `EquinoxDomain.Windowing.slice/2`（`:beat_ticks` / `:tpqn` /
  `:extra_spans`）。
  """
  @spec slice(Project.t(), Coconut.Edit.Track.track_id(), keyword()) ::
          {:ok, [Windowing.Window.t()]} | {:error, term()}
  def slice(%Project{} = project, track_id, opts \\ []) do
    with {:ok, entries} <- notes(project, track_id) do
      Windowing.slice(entries, opts)
    end
  end
end
