defmodule EquinoxDomain.Command do
  # 外部指令，等价于 DDD 的 Usecase

  # 涉及到复杂指令（设计诸多对象）的
  # 单独拎出来

  # 打个比方：
  # 比方说同样是拖拽音符
  # 在 Note 层面就不需要引入 Command
  # 如果是人声的单声部轨道（存在禁止同一时刻有多个音的情况）
  # 就需要考虑该轨道的其他音符
  # 表现为 UI 层面置灰，直到修改合法
  # 这个操作的 Aggregate 在 Track
  # 一些 Project 层面的同理
end
