ExUnit.start()

defmodule EquinoxDomain.TestFactory do
  @moduledoc """
  测试场景搭建：Project + Vocal 轨 + 音符（经 coconut History 写入）。

  domain 测试只搭查询/投影场景，不复测 coconut 的写路径语义
  （op 应用、transport 等已在 coconut 自有测试覆盖）。
  """

  alias Coconut.Edit.History
  alias Coconut.Edit.Operations.InsertNote
  alias EquinoxDomain.Score.Project

  @doc "空工程（缺省 id `Project_test`）。"
  def new_project(id \\ "Project_test") do
    {:ok, project} = Project.new(id: id)
    project
  end

  @doc "工程 + 一条 Vocal 轨（缺省 id `Track_1`），返回 `{project, track_id}`。"
  def project_with_track(track_id \\ "Track_1") do
    project = new_project()
    {:ok, project, _track} = Project.add_track(project, id: track_id, name: track_id)
    {project, track_id}
  end

  @doc """
  经 `Coconut.Edit.History` 批量插入音符，返回写后的 project。

  `notes` 为 `[{note_id, start_tick, end_tick}]` 或
  `[{note_id, start_tick, end_tick, attrs}]`（attrs 透传 Note cast，
  如 `%{pitch: 60, lyric: "あ"}`）。
  """
  def insert_notes(project, track_id, notes) do
    hist = History.new(project.workspace)

    hist =
      Enum.reduce(notes, hist, fn note, hist ->
        {note_id, start_tick, end_tick, attrs} =
          case note do
            {id, s, e} -> {id, s, e, %{}}
            {id, s, e, attrs} -> {id, s, e, attrs}
          end

        {:ok, hist} =
          History.apply(hist, %InsertNote{
            track_id: track_id,
            note_id: note_id,
            after_id: :head,
            span: {start_tick, end_tick},
            attrs: attrs
          })

        hist
      end)

    %{project | workspace: hist.present}
  end

  @doc "编译一个 120BPM 恒定 tempo map（tpqn 480）。"
  def tempo_map do
    alias Coconut.Score.{Tempo, TempoMap}

    {:ok, tempo_map} =
      TempoMap.compile([{0, %Tempo.Event{module: Tempo.Step, context: %{bpm: 120.0}}}])

    tempo_map
  end
end

defmodule EquinoxDomain.PickleTestHelper do
  @moduledoc """
  dump 产物的「允许类型」递归断言。

  只允许 map / list / number / binary / atom / boolean / nil
  （map 键限 atom / binary / number）；任何 tuple / struct / fun /
  pid / port / reference 直接 fail。所有 dump 测试都应过一遍。
  """

  import ExUnit.Assertions

  @doc "递归断言 term 是 dump-safe 的 plain 数据，否则 flunk。"
  def assert_plain!(term), do: check!(term)

  defp check!(%_{} = struct), do: flunk("dump 产物含 struct：#{inspect(struct)}")

  defp check!(%{} = map) do
    Enum.each(map, fn {key, value} ->
      check_key!(key)
      check!(value)
    end)
  end

  defp check!(list) when is_list(list), do: Enum.each(list, &check!/1)

  defp check!(term) when is_number(term) or is_binary(term) or is_atom(term), do: :ok

  defp check!(term), do: flunk("dump 产物含不允许的类型：#{inspect(term)}")

  defp check_key!(key) when is_atom(key) or is_binary(key) or is_number(key), do: :ok
  defp check_key!(key), do: flunk("dump 产物含不允许的 map 键：#{inspect(key)}")
end
