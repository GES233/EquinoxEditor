defmodule NeumeLab do
  @moduledoc """
  Neume 实验台：Livebook/Kino 壳层，验证 Neumu facade 契约的交互闭环。

  本 app 是开发工具，不含产品语义：fixture 声库、假 G2P client 与
  正弦合成渲染器只为在笔记本里跑通"编辑 → 冲突 → repatch → 按 pin
  渲染 → 并排试听"四步，不触碰真实 DiffSinger 推理。

  运行形态：Livebook 以 **Attached** 模式附着到本 umbrella 启动的节点
  （`iex --sname equinox --cookie equinox -S mix`），notebook 直接调用
  `NeumeLab` 与 `Neumu` 的已加载代码。见 `notebooks/lab.livemd`。
  """
end
