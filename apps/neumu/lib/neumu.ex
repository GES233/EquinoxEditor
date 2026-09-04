defmodule Neumu do
  @moduledoc """
  Neumu application service：Neume 引擎之上的工程会话与渲染任务入口，
  也是 UI-facing backend facade。

  每个打开的工程由一个 `Neumu.ProjectServer` 持有唯一的
  `Neume.MultiTrack` 值；UI 不直接持有或修改 `Neume.MultiTrack` /
  `Coconut.Session`，所有编辑经本模块的命令函数串行进入对应
  ProjectServer。查询（`snapshot/1` 等）返回只读 plain data 投影
  （`Neumu.ProjectSnapshot`），不含 PID、worker、Oi compiled graph 等
  运行时对象。

  渲染经 `Neumu.RenderSupervisor` 异步执行，制品存入
  `Neumu.ArtifactStore` 并分配不透明 `artifact_id`。订阅者只收到三种
  事件 payload（见 `Neume.Event`），事件只携带重新查询权威状态所需的
  identity。
  """

  alias Coconut.Edit.Workspace
  alias Coconut.Project
  alias Coconut.Util.ID
  alias Neume.RenderJob
  alias Neume.Voicebank.Registry, as: VoicebankRegistry

  @type artifact_id :: Neumu.ArtifactStore.artifact_id()
  @type history_pin :: Coconut.Edit.History.node_id()

  # 透传给 ProjectServer 的选项键；其余选项交给 Neume.MultiTrack.open/load。
  @server_opts [:renderer, :render_supervisor, :artifact_store, :event_registry]

  # --- 工程生命周期 ---

  @doc """
  新建一个空工程（无轨道）并打开对应的 `Neumu.ProjectServer`。

  选项：

  - `:voicebank_registry` — 声库注册表（`Neume.Voicebank.Registry`），
    缺省时按 `:neume, :voicebank_roots` 应用配置发现；后续
    `add_track/4` / `rebind_voicebank/3` 用它解析 `voicebank_id`；
  - `:metadata` — 写入 `Coconut.Project` 的元数据；
  - 其余选项（如 `:output_dir`、`:diffsinger_client`）透传给
    `Neume.MultiTrack.open/2`；`@server_opts` 中的选项透传给
    `Neumu.ProjectServer`。
  """
  @spec create_project(RenderJob.project_id(), keyword()) :: {:ok, pid()} | {:error, term()}
  def create_project(project_id, opts \\ [])

  def create_project(nil, _opts), do: {:error, {:invalid_project_id, nil}}

  def create_project(project_id, opts) do
    {server_opts, open_opts} = Keyword.split(opts, @server_opts)

    with {:ok, registry} <- voicebank_registry(open_opts),
         {:ok, workspace} <-
           Workspace.new(%{id: ID.generate_id("WSpc_"), tracks: %{}}),
         {:ok, project} <-
           Project.new(%{
             id: project_id,
             workspace: workspace,
             voicebank: nil,
             metadata: Keyword.get(open_opts, :metadata, %{})
           }),
         {:ok, multi_track} <-
           Neume.MultiTrack.open(project, prepare_open_opts(open_opts, registry)) do
      open_project(project_id, multi_track, server_opts)
    end
  end

  @doc """
  从工程文件加载并打开工程；v2 档恢复存档的 undo/redo History。

  复用 `Neume.MultiTrack.load/2`（`Coconut.Pickle.File`），不另造文件
  格式。选项同 `create_project/2`（`:metadata` 除外——元数据来自存档）。
  """
  @spec load_project(RenderJob.project_id(), Path.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def load_project(project_id, path, opts \\ [])

  def load_project(nil, _path, _opts), do: {:error, {:invalid_project_id, nil}}

  def load_project(project_id, path, opts) do
    {server_opts, load_opts} = Keyword.split(opts, @server_opts)

    with {:ok, registry} <- voicebank_registry(load_opts),
         {:ok, multi_track} <-
           Neume.MultiTrack.load(path, prepare_open_opts(load_opts, registry)) do
      open_project(project_id, multi_track, server_opts)
    end
  end

  @doc """
  保存工程快照与 undo/redo History 到 `path`。

  保存不改变工程状态，不产生 History 边，也不派发事件。
  """
  @spec save_project(RenderJob.project_id(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def save_project(project_id, path) do
    call_project(project_id, {:save, path})
  end

  @doc """
  打开工程并启动对应的 `Neumu.ProjectServer`。

  `multi_track` 必须是已经 `Neume.MultiTrack.open/2` 好的工程值；本服务
  不复制 Neume 的打开/声库解析语义。`:renderer` 等选项透传给
  `Neumu.ProjectServer.start_link/1`。`project_id` 为 `nil` 时返回
  `{:error, {:invalid_project_id, nil}}`。
  """
  @spec open_project(RenderJob.project_id(), Neume.MultiTrack.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def open_project(project_id, multi_track, opts \\ [])

  def open_project(nil, %Neume.MultiTrack{}, _opts) do
    {:error, {:invalid_project_id, nil}}
  end

  def open_project(project_id, %Neume.MultiTrack{} = multi_track, opts) do
    opts = opts |> Keyword.put(:project_id, project_id) |> Keyword.put(:multi_track, multi_track)

    case DynamicSupervisor.start_child(Neumu.ProjectSupervisor, {Neumu.ProjectServer, opts}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        {:error, {:project_already_open, project_id}}

      {:error, _} = error ->
        error
    end
  end

  @doc "关闭工程并终止其 ProjectServer；未打开时返回 tagged error。"
  @spec close_project(RenderJob.project_id()) :: :ok | {:error, term()}
  def close_project(project_id) do
    case Neumu.ProjectServer.whereis(project_id) do
      nil -> {:error, {:unknown_project, project_id}}
      pid -> DynamicSupervisor.terminate_child(Neumu.ProjectSupervisor, pid)
    end
  end

  # --- 只读查询 ---

  @doc """
  查询工程当前 History cursor 下的权威只读快照（`Neumu.ProjectSnapshot`）。

  查询不产生 History 边、不派发事件；快照的 `history_pin` 与生成时的
  cursor 一致。
  """
  @spec snapshot(RenderJob.project_id()) ::
          {:ok, Neumu.ProjectSnapshot.t()} | {:error, term()}
  def snapshot(project_id) do
    call_project(project_id, :snapshot)
  end

  @doc "查询工程当前的 History cursor node id（版本钉）。"
  @spec history_pin(RenderJob.project_id()) :: {:ok, history_pin()} | {:error, term()}
  def history_pin(project_id) do
    call_project(project_id, :history_pin)
  end

  @doc "按 `artifact_id` 查询运行时制品。"
  @spec artifact(artifact_id()) ::
          {:ok, RenderJob.artifact()} | {:error, Neumu.ArtifactStore.not_found()}
  def artifact(artifact_id), do: Neumu.ArtifactStore.fetch(artifact_id)

  # --- 编辑命令 ---

  # 所有命令串行进入对应 ProjectServer。成功且实际产生 History 边时返回
  # 新的 history_pin 并派发一次 `{:project_changed, project_id, history_pin}`；
  # 无变化的编辑（如无改动的 globals 合并）返回当前 pin 且不派发事件；
  # 失败编辑返回 tagged error，不改状态、不派发事件。

  @doc "插入一个音符。`span` 为半开 tick 区间 `{start_tick, end_tick}`。"
  @spec insert_note(
          RenderJob.project_id(),
          Coconut.Edit.Track.track_id(),
          term(),
          term(),
          Coconut.Edit.Track.span(),
          map()
        ) ::
          {:ok, history_pin()} | {:error, term()}
  def insert_note(project_id, track_id, note_id, after_id, span, attrs) do
    edit(project_id, {:insert_note, track_id, note_id, after_id, span, attrs})
  end

  @doc "修改音符内容（音高、歌词、annotation、metadata）；移动时间位置请用 `move_note/5`。"
  @spec edit_note(RenderJob.project_id(), Coconut.Edit.Track.track_id(), term(), map()) ::
          {:ok, history_pin()} | {:error, term()}
  def edit_note(project_id, track_id, note_id, changes) do
    edit(project_id, {:edit_note, track_id, note_id, changes})
  end

  @doc "把音符移动到新 span（同时可改序）；`after_id` 取 `:head` 或某音符 id。"
  @spec move_note(
          RenderJob.project_id(),
          Coconut.Edit.Track.track_id(),
          term(),
          term(),
          Coconut.Edit.Track.span()
        ) ::
          {:ok, history_pin()} | {:error, term()}
  def move_note(project_id, track_id, note_id, after_id, span) do
    edit(project_id, {:move_note, track_id, note_id, after_id, span})
  end

  @doc "删除一个音符。"
  @spec delete_note(RenderJob.project_id(), Coconut.Edit.Track.track_id(), term()) ::
          {:ok, history_pin()} | {:error, term()}
  def delete_note(project_id, track_id, note_id) do
    edit(project_id, {:delete_note, track_id, note_id})
  end

  @doc """
  新增一条人声轨；`voicebank_id` 经工程的声库注册表解析。

  `attrs` 支持 `:name` 与 `:mix`（见 `Neume.TrackConfig`）。未知声库返回
  `{:error, {:voicebank_not_registered, voicebank_id}}`。
  """
  @spec add_track(RenderJob.project_id(), Coconut.Edit.Track.track_id(), String.t(), map()) ::
          {:ok, history_pin()} | {:error, term()}
  def add_track(project_id, track_id, voicebank_id, attrs \\ %{}) do
    edit(project_id, {:add_track, track_id, voicebank_id, attrs})
  end

  @doc "删除一条轨道（记入可 undo 的工程唯一 History）。"
  @spec remove_track(RenderJob.project_id(), Coconut.Edit.Track.track_id()) ::
          {:ok, history_pin()} | {:error, term()}
  def remove_track(project_id, track_id) do
    edit(project_id, {:remove_track, track_id})
  end

  @doc "重绑定轨道声库；`voicebank_id` 经工程的声库注册表解析。"
  @spec rebind_voicebank(RenderJob.project_id(), Coconut.Edit.Track.track_id(), String.t()) ::
          {:ok, history_pin()} | {:error, term()}
  def rebind_voicebank(project_id, track_id, voicebank_id) do
    edit(project_id, {:rebind_voicebank, track_id, voicebank_id})
  end

  @doc "更新轨道 mix 参数（`%{gain: _, pan: _, mute: _}` 的子集，合并语义）。"
  @spec update_mix(RenderJob.project_id(), Coconut.Edit.Track.track_id(), map()) ::
          {:ok, history_pin()} | {:error, term()}
  def update_mix(project_id, track_id, attrs) do
    edit(project_id, {:update_mix, track_id, attrs})
  end

  @doc "更新轨道级全局表现旋钮（key 合并，nil 删除该键）；无变化时不落历史边。"
  @spec update_globals(RenderJob.project_id(), Coconut.Edit.Track.track_id(), map()) ::
          {:ok, history_pin()} | {:error, term()}
  def update_globals(project_id, track_id, knobs) do
    edit(project_id, {:update_globals, track_id, knobs})
  end

  @doc "撤销工程中的上一条历史边；无可撤销时返回 `{:error, :nothing_to_undo}`。"
  @spec undo(RenderJob.project_id()) :: {:ok, history_pin()} | {:error, term()}
  def undo(project_id), do: edit(project_id, :undo)

  @doc "重做工程中的下一条历史边；无可重做时返回 `{:error, :nothing_to_redo}`。"
  @spec redo(RenderJob.project_id()) :: {:ok, history_pin()} | {:error, term()}
  def redo(project_id), do: edit(project_id, :redo)

  # --- 渲染任务 ---

  @doc """
  提交一次渲染。

  捕获当前 Coconut History cursor node id 作为 `source_pin` 创建
  `Neume.RenderJob`，任务在 ProjectServer 之外执行。返回处于 `:running`
  状态的权威 job。选项：

  - `:renderer` — 覆盖本次渲染的渲染函数（测试注入用）；
  - `:job_id` — 指定任务 id，默认生成唯一整数；该工程内已存在同名
    job（在途或终态）时返回 `{:error, {:job_already_exists, job_id}}`，
    不覆盖权威 job。
  """
  @spec submit_render(RenderJob.project_id(), keyword()) ::
          {:ok, RenderJob.t()} | {:error, term()}
  def submit_render(project_id, opts \\ []) do
    call_project(project_id, {:submit_render, opts})
  end

  @doc """
  按 `job_id` 查询该工程内的权威 job 状态。

  未找到时返回 `{:error, {:job_not_found, job_id}}`。
  """
  @spec render_job(RenderJob.project_id(), RenderJob.id()) ::
          {:ok, RenderJob.t()} | {:error, term()}
  def render_job(project_id, job_id) do
    call_project(project_id, {:render_job, job_id})
  end

  # --- 事件订阅 ---

  @doc """
  订阅工程事件；当前进程将收到该工程的三种事件 payload。

  订阅幂等：同一进程重复订阅只登记一次，每个事件只投递一次。
  工程未打开时也允许订阅，事件只在工程存活期间派发。
  """
  @spec subscribe(RenderJob.project_id()) :: :ok
  def subscribe(project_id) do
    unless subscribed?(project_id) do
      {:ok, _} = Registry.register(Neumu.EventRegistry, project_id, [])
    end

    :ok
  end

  # 当前进程是否已订阅该工程。
  defp subscribed?(project_id) do
    Neumu.EventRegistry
    |> Registry.lookup(project_id)
    |> Enum.any?(fn {pid, _value} -> pid == self() end)
  end

  @doc "退订工程事件。"
  @spec unsubscribe(RenderJob.project_id()) :: :ok
  def unsubscribe(project_id) do
    :ok = Registry.unregister(Neumu.EventRegistry, project_id)
    :ok
  end

  # --- 内部 ---

  defp edit(project_id, command), do: call_project(project_id, {:edit, command})

  defp call_project(project_id, message) do
    case Neumu.ProjectServer.whereis(project_id) do
      nil -> {:error, {:unknown_project, project_id}}
      pid -> GenServer.call(pid, message)
    end
  end

  defp voicebank_registry(opts) do
    case Keyword.fetch(opts, :voicebank_registry) do
      {:ok, %VoicebankRegistry{} = registry} -> {:ok, registry}
      {:ok, other} -> {:error, {:invalid_voicebank_registry, other}}
      :error -> VoicebankRegistry.discover_configured()
    end
  end

  defp prepare_open_opts(opts, registry) do
    opts
    |> Keyword.put(:voicebank_registry, registry)
    |> Keyword.drop([:metadata])
  end
end
