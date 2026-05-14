defmodule EquinoxDomain.Score.Slicer do
  @moduledoc """
  将一组音符按时间轴划分为窗口。

  每个窗口包含在时间上连续的音符。
  「连续」由 `gap_tolerance` 与每个音符的 `slice_flag` 共同决定。
  """

  alias EquinoxDomain.Score.Note

  defmodule Window do
    @moduledoc "一个切片窗口，包含时间范围与音符 ID 列表。"
    alias EquinoxDomain.Util.ID
    alias EquinoxDomain.Timeline.Tick

    @type t :: %__MODULE__{
            tick_start: Tick.numeric_tick(),
            tick_end: Tick.numeric_tick(),
            note_ids: [ID.t(Note)]
          }
    use EquinoxDomain.Util.Object,
      keys: [
        :tick_start,
        :tick_end,
        note_ids: []
      ]

    def build(%Note{} = note) do
      new(
        tick_start: note.start_tick,
        tick_end: note.start_tick + note.duration_tick,
        note_ids: [note.id]
      )
    end

    def append(%__MODULE__{} = window, %Note{} = note) do
      note_end = note.start_tick + note.duration_tick

      update(window,
        tick_end: max(window.tick_end, note_end),
        note_ids: window.note_ids ++ [note.id]
      )
    end
  end

  @type option ::
          {:gap_tolerance, non_neg_integer()}
          | {:default_flag, Note.slice_flag()}

  @default_gap_tolerance 64

  @doc "将音符列表划分为时间窗口。"
  @spec index([Note.t()], [option]) :: {:ok, [Window.t()]} | {:error, term()}
  def index(notes, opts \\ [])

  def index([], _opts), do: {:ok, []}

  def index(notes, opts) when is_list(notes) do
    gap_tolerance = Keyword.get(opts, :gap_tolerance, @default_gap_tolerance)

    sorted = Enum.sort_by(notes, & &1.start_tick)

    Enum.reduce_while(sorted, {:ok, [], nil}, fn note, {:ok, acc, current} ->
      case do_insert(note, current, gap_tolerance) do
        {:merge, {:ok, updated}} ->
          {:cont, {:ok, acc, updated}}

        {:split, {:ok, new}} ->
          acc = if is_nil(current), do: acc, else: [current | acc]
          {:cont, {:ok, acc, new}}

        {_op, {:error, _reason} = err} ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, acc, nil} ->
        {:ok, Enum.reverse(acc)}

      {:ok, acc, current} ->
        {:ok, Enum.reverse([current | acc])}

      {:error, _reason} = err ->
        err
    end
  end

  # ---- 内部逻辑 ----

  defp do_insert(note, nil, _gap) do
    {:split, build_window(note)}
  end

  defp do_insert(%{slice_flag: :force_slice} = note, _current, _gap) do
    {:split, build_window(note)}
  end

  defp do_insert(%{slice_flag: :force_merge} = note, current, _gap) do
    {:merge, append_note(current, note)}
  end

  defp do_insert(%{slice_flag: :auto} = note, current, gap_tolerance) do
    if gap_exceeds?(current, note, gap_tolerance) do
      {:split, build_window(note)}
    else
      {:merge, append_note(current, note)}
    end
  end

  defp gap_exceeds?(window, note, gap_tolerance),
    do: note.start_tick - window.tick_end > gap_tolerance

  defp build_window(note), do: Window.build(note)

  defp append_note(window, note), do: Window.append(window, note)
end
