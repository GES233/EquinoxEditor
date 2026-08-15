defmodule Equinox.Kernel.Voicebank do
  @moduledoc """
  声库描述符——引擎侧的资产描述 VO（约定形状，见
  `docs/engine-adapter-design.md`「声库设计草案」）。

  **不是领域事实**：不进 Domain struct、不进 History、不参与 undo（与
  TrackMeta 侧表同级的产品判断）。挂载点是 Adapter config——
  `engines: %{"qiyu_v2" => {MyAdapter, %{voicebank: vb}}}`，
  「换声库 = 换 Adapter config」，kernel 零感知具体字段语义。
  声库资产的发现 / 注册机制（目录扫描、显式注册表）是 userland 运行时
  职责，本模块只约定描述符形状。

  Adapter 的消费约定（参考实现：`Equinox.Kernel.StubEngineAdapter`）：

  - `engine_key/1` — `"id@engine_version"` 版本戳，进 digest base；
  - `capabilities.supported_channels` — 派生 `channels/1` 的 channel 列表；
  - `timing` — `timing_spec/1` 的帧网格声明来源（`frame_rate` / `hop`）。

  `models` / `dictionary` 等载荷对 kernel 不透明（只做 map 校验）。
  """

  import Coconut.Util.Helpers, only: [normalize_attrs: 2]

  @type t :: %__MODULE__{
          id: binary(),
          engine: atom(),
          engine_version: binary(),
          models: map(),
          dictionary: map(),
          capabilities: map(),
          timing: map()
        }

  @keys [
    id: nil,
    engine: nil,
    engine_version: nil,
    models: %{},
    dictionary: %{},
    capabilities: %{},
    timing: %{}
  ]
  defstruct @keys

  @doc "创建声库描述符（`id` / `engine` / `engine_version` 必填，其余有缺省）。"
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
      struct(__MODULE__, normalized) |> validate()
    end
  end

  @doc "校验必填三元组与载荷形状（map 类字段只做浅校验，内容对 kernel 不透明）。"
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = vb) do
    cond do
      not (is_binary(vb.id) and vb.id != "") ->
        {:error, {:invalid_id, vb.id}}

      not is_atom(vb.engine) or is_nil(vb.engine) ->
        {:error, {:invalid_engine, vb.engine}}

      not (is_binary(vb.engine_version) and vb.engine_version != "") ->
        {:error, {:invalid_engine_version, vb.engine_version}}

      not is_map(vb.models) ->
        {:error, {:invalid_models, vb.models}}

      not is_map(vb.dictionary) ->
        {:error, {:invalid_dictionary, vb.dictionary}}

      not is_map(vb.capabilities) ->
        {:error, {:invalid_capabilities, vb.capabilities}}

      not is_map(vb.timing) ->
        {:error, {:invalid_timing, vb.timing}}

      true ->
        with :ok <- check_atom_list(vb.capabilities, :supported_channels),
             :ok <- check_atom_list(vb.capabilities, :supported_params),
             :ok <- check_timing(vb.timing) do
          {:ok, vb}
        end
    end
  end

  # capabilities 的消费键若存在必须是 atom 列表（Adapter 据此派生 specs）
  defp check_atom_list(capabilities, key) do
    case Map.get(capabilities, key) do
      nil ->
        :ok

      list when is_list(list) ->
        if Enum.all?(list, &is_atom/1),
          do: :ok,
          else: {:error, {:invalid_capabilities, {key, list}}}

      other ->
        {:error, {:invalid_capabilities, {key, other}}}
    end
  end

  # timing 的帧网格键若存在必须是正整数（frame_rate / hop）
  defp check_timing(timing) do
    Enum.reduce_while([:frame_rate, :hop], :ok, fn key, :ok ->
      case Map.get(timing, key) do
        nil -> {:cont, :ok}
        n when is_integer(n) and n > 0 -> {:cont, :ok}
        other -> {:halt, {:error, {:invalid_timing, {key, other}}}}
      end
    end)
  end

  @doc "引擎身份键（`\"id@engine_version\"`）——进 digest base 的版本戳约定。"
  @spec engine_key(t()) :: String.t()
  def engine_key(%__MODULE__{} = vb), do: "#{vb.id}@#{vb.engine_version}"

  # ---- 序列化（plain map codec，与 Coconut.Pickle 约定一致） ----

  @doc "摊平为 plain map（全字段直出）。"
  @spec dump(t()) :: {:ok, map()}
  def dump(%__MODULE__{} = vb) do
    {:ok,
     %{
       id: vb.id,
       engine: vb.engine,
       engine_version: vb.engine_version,
       models: vb.models,
       dictionary: vb.dictionary,
       capabilities: vb.capabilities,
       timing: vb.timing
     }}
  end

  @doc "从 plain map 重建（经 `new/1` 校验生效）。"
  @spec load(map()) :: {:ok, t()} | {:error, term()}
  def load(%{} = data) do
    data
    |> Map.take([:id, :engine, :engine_version, :models, :dictionary, :capabilities, :timing])
    |> new()
  end

  def load(other), do: {:error, {:invalid_voicebank_dump, other}}
end
