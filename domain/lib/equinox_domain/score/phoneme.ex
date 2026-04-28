defmodule EquinoxDomain.Score.Phoneme do
  @moduledoc "音素模型。"
  # 需要 Adapter 来适配注入 IPA 、汉语拼音、拆音、含有语言 ID 的音素等情况
  # 是不是还要考虑时域信息，比方说复元音之类的

  # 在这里构思下吧如果把辅音放开头的情况
  # 运用隐式填充的路子
  # 整体 offset （包括其他轨道）进行渲染
  # 出来后再截掉
  # 或者是一个警报，辅音空间不足，最好重新安排
  # 那就这样：操作过程警报，渲染时实际存在就填充

  # 另外一点是音素挂载在什么下面？音符？还是歌词？貌似和歌词关系更大吧

  @type symbol :: String.t()
  @type phoneme_type :: :consonant | :vowel | :silence

  @type t :: %__MODULE__{
          symbol: symbol(),
          type: phoneme_type(),
          # 之所以不是非负整数，是要考虑辅音的 offset 是负的
          # 拍子从元音开始算
          tick_offset: integer(),
          duration_tick: integer()
        }
  defstruct [:symbol, :type, :tick_offset, :duration_tick]
end
