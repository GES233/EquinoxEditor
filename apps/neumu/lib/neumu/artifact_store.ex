defmodule Neumu.ArtifactStore do
  @moduledoc """
  运行时制品存储。

  登记并查询 `Neume` 产出的制品（`Neume.RenderArtifact` 与
  `Neume.MixArtifact`），为每个制品分配不透明、进程内唯一的
  `artifact_id`。存储只维护在当前节点运行时内存中，不持久化，
  也不管理制品引用的任何文件的生命周期；制品不进入工程文件与编辑历史。
  """

  use GenServer

  @typedoc "不透明、进程内唯一的制品标识。"
  @type artifact_id :: String.t()

  @typedoc "可登记的制品类型。"
  @type artifact :: Neume.RenderArtifact.t() | Neume.MixArtifact.t()

  @typedoc "查询或删除失败时的原因。"
  @type not_found :: {:artifact_not_found, artifact_id()}

  # --- 公开接口 ---

  @doc "启动制品存储，默认以 `Neumu.ArtifactStore` 命名。"
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @doc """
  登记一个制品，返回 `{:ok, artifact_id}`。

  只接受 `Neume.RenderArtifact` 与 `Neume.MixArtifact`，其余输入返回
  `{:error, {:invalid_artifact, value}}`。
  """
  @spec put(GenServer.server(), artifact()) ::
          {:ok, artifact_id()} | {:error, {:invalid_artifact, term()}}
  def put(server \\ __MODULE__, artifact)

  def put(server, %Neume.RenderArtifact{} = artifact),
    do: GenServer.call(server, {:put, artifact})

  def put(server, %Neume.MixArtifact{} = artifact),
    do: GenServer.call(server, {:put, artifact})

  def put(_server, other), do: {:error, {:invalid_artifact, other}}

  @doc """
  按 `artifact_id` 查询制品。

  命中返回 `{:ok, artifact}`，未知标识返回
  `{:error, {:artifact_not_found, artifact_id}}`。
  """
  @spec fetch(GenServer.server(), artifact_id()) ::
          {:ok, artifact()} | {:error, not_found()}
  def fetch(server \\ __MODULE__, artifact_id) do
    GenServer.call(server, {:fetch, artifact_id})
  end

  @doc """
  删除一个制品。

  成功返回 `:ok`；未知标识返回
  `{:error, {:artifact_not_found, artifact_id}}`。删除只影响内存登记，
  不会删除制品引用的任何文件。
  """
  @spec delete(GenServer.server(), artifact_id()) :: :ok | {:error, not_found()}
  def delete(server \\ __MODULE__, artifact_id) do
    GenServer.call(server, {:delete, artifact_id})
  end

  # --- GenServer 回调 ---

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:put, artifact}, _from, artifacts) do
    artifact_id = new_artifact_id()
    {:reply, {:ok, artifact_id}, Map.put(artifacts, artifact_id, artifact)}
  end

  def handle_call({:fetch, artifact_id}, _from, artifacts) do
    case Map.fetch(artifacts, artifact_id) do
      {:ok, artifact} -> {:reply, {:ok, artifact}, artifacts}
      :error -> {:reply, {:error, {:artifact_not_found, artifact_id}}, artifacts}
    end
  end

  def handle_call({:delete, artifact_id}, _from, artifacts) do
    if Map.has_key?(artifacts, artifact_id) do
      {:reply, :ok, Map.delete(artifacts, artifact_id)}
    else
      {:reply, {:error, {:artifact_not_found, artifact_id}}, artifacts}
    end
  end

  # 不透明 id：单调唯一整数，与 job、工程 identity 无关。
  defp new_artifact_id do
    "artifact-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
