defmodule EquinoxDomain.Port.Channel do
  @moduledoc """
  数据通道标识——对齐 coconut `Coconut.Edit.Patch.channel` 的 atom 类型。

  另提供 digest base 的引擎版本戳组合（`stamp_base/2`）：声库 / 引擎版本
  必须进 digest base（版本升级 = 全部 digest 失配 = conflict 风暴，这是
  显式接受的最坏情形）。挂载侧（`AdoptRequest.build_patch/3` 的 `:engine`
  选项）与 check 侧（EngineAdapter 供给的 spec projection）共用本函数，
  保证两个调用点逐位一致（`docs/engine-adapter-design.md` Channel 本体
  纪律）。
  """

  @type channel :: atom()

  @doc """
  把引擎版本戳组合进 canonical base：`%{"engine" => key, "base" => base}`。

  `base` 须已是 canonical term（channel 模块的投影产物）；`engine_key`
  为二进制（约定 `"声库id@引擎版本"`）。产物本身仍是 canonical term，
  可直接作 `Tamale.Patch.new/2` / `Tamale.Patch.resolve/2` 的 digest 输入。
  """
  @spec stamp_base(Tamale.Digest.canonical(), binary()) :: Tamale.Digest.canonical()
  def stamp_base(base, engine_key) when is_binary(engine_key),
    do: %{"engine" => engine_key, "base" => base}
end
