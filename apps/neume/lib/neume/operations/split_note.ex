defmodule Neume.Operations.SplitNote do
  @moduledoc """
  拆音手势：coconut `SplitNote` + 右子补 melisma 续音旗标（同一历史边）。

  拆分 = 同音节延续（VOCALOID/SynthV 语义）：左子继承父 id 与内容，右子
  获得 `metadata["melisma"] == "continue"`；因子音符贴接，右子自动并入
  左子所在组。拆续音音符时右子本就复制旗标，此处幂等。需要两个独立
  音节时，事后 `Editor.edit_note/3` 清除右子旗标或拖出缝隙。
  """

  alias Coconut.Edit.{Operation, Workspace}
  alias Coconut.Edit.Operations.SplitNote
  alias Coconut.Score.Note

  @behaviour Coconut.Edit.Operation

  @type t :: %__MODULE__{
          track_id: Operation.track_id(),
          note_id: Note.note_id(),
          at_tick: non_neg_integer(),
          new_id: Note.note_id()
        }
  defstruct [:track_id, :note_id, :at_tick, :new_id]

  @impl true
  def validate(%__MODULE__{} = request, %Workspace{} = workspace) do
    SplitNote.validate(to_split(request), workspace)
  end

  @impl true
  def lower(%__MODULE__{} = request, %Workspace{} = workspace, %Operation.Config{} = config) do
    with {:ok, ops, changes} <- SplitNote.lower(to_split(request), workspace, config) do
      {:ok, ops, flag_right_child(changes, request.new_id)}
    end
  end

  defp to_split(request) do
    %SplitNote{
      track_id: request.track_id,
      note_id: request.note_id,
      at_tick: request.at_tick,
      new_id: request.new_id
    }
  end

  defp flag_right_child(changes, new_id) do
    case changes.elements do
      %{^new_id => %Note{} = right} = elements ->
        metadata = Map.put(right.metadata || %{}, "melisma", "continue")
        %{changes | elements: %{elements | new_id => %{right | metadata: metadata}}}

      _other ->
        changes
    end
  end
end
