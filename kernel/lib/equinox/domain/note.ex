defmodule Equinox.Domain.Note do
  @moduledoc """
  离散音符事件 (Pure Data)。
  采用 Tick 作为绝对时间单位。
  """

  @type id :: String.t()
  @type slice_id :: String.t()
  @type slice_flag :: {:on_start, slice_id()} | :on_end | nil

  @type t :: %__MODULE__{
          id: id(),
          start_tick: non_neg_integer(),
          duration_tick: pos_integer(),
          key: integer(),
          lyric: String.t(),
          phoneme: String.t() | nil,
          slice_flag: slice_flag(),
          extra: map()
        }

  @derive {Jason.Encoder,
           only: [:id, :start_tick, :duration_tick, :key, :lyric, :phoneme, :slice_flag, :extra]}
  defstruct [:id, :start_tick, :duration_tick, :key, :lyric, :phoneme, :slice_flag, extra: %{}]

  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}) do
    attrs = Equinox.Utils.AttributesHelper.normalize(attrs)

    %__MODULE__{}
    |> struct!(%{
      id: Map.get(attrs, :id, Equinox.Utils.ID.generate()),
      start_tick: Map.get(attrs, :start_tick, 0),
      duration_tick: Map.get(attrs, :duration_tick, 480),
      key: Map.get(attrs, :key, 60),
      lyric: Map.get(attrs, :lyric, "la"),
      phoneme: Map.get(attrs, :phoneme),
      slice_flag: normalize_slice_flag(Map.get(attrs, :slice_flag)),
      extra: Map.get(attrs, :extra, %{})
    })
  end

  @spec update(t(), map() | keyword()) :: t()
  def update(%__MODULE__{} = note, attrs) do
    attrs = Equinox.Utils.AttributesHelper.normalize(attrs)

    updates =
      attrs
      |> Map.take([:start_tick, :duration_tick, :key, :lyric, :phoneme, :slice_flag, :extra])
      |> Map.update(:slice_flag, note.slice_flag, &normalize_slice_flag/1)
      |> Map.update(:extra, note.extra, &Map.merge(note.extra, &1))

    struct!(note, updates)
  end

  @spec merge(t(), t()) :: {:ok, t()} | {:error, :notes_do_not_touch}
  def merge(%__MODULE__{} = note1, %__MODULE__{} = note2) do
    [first_note, second_note] = Enum.sort_by([note1, note2], &{&1.start_tick, &1.id})
    %__MODULE__{} = left = first_note
    %__MODULE__{} = right = second_note

    if end_tick(left) < right.start_tick do
      {:error, :notes_do_not_touch}
    else
      {:ok,
       %{
         left
         | duration_tick: max(end_tick(left), end_tick(right)) - left.start_tick,
           lyric: pick_merge_value(left.lyric, right.lyric),
           phoneme: pick_merge_value(left.phoneme, right.phoneme),
           slice_flag: normalize_slice_flag(left.slice_flag || right.slice_flag),
           extra: Map.merge(left.extra, right.extra)
       }}
    end
  end

  @spec split(t(), integer(), map() | keyword()) :: {:ok, {t(), t()}} | {:error, :invalid_split_tick}
  def split(%__MODULE__{} = note, split_tick, attrs \\ %{}) when is_integer(split_tick) do
    attrs = Equinox.Utils.AttributesHelper.normalize(attrs)

    if split_tick <= note.start_tick or split_tick >= end_tick(note) do
      {:error, :invalid_split_tick}
    else
      left_duration = split_tick - note.start_tick
      right_duration = end_tick(note) - split_tick
      left_attrs = Equinox.Utils.AttributesHelper.normalize(Map.get(attrs, :left, %{}))
      right_attrs = Equinox.Utils.AttributesHelper.normalize(Map.get(attrs, :right, %{}))

      left_note =
        note
        |> update(%{duration_tick: left_duration, slice_flag: nil})
        |> update(left_attrs)

      right_note =
        %__MODULE__{}
        |> struct!(%{
          note
          | id: Map.get(right_attrs, :id, Equinox.Utils.ID.generate()),
            start_tick: split_tick,
            duration_tick: right_duration,
            slice_flag: nil
        })
        |> update(Map.delete(right_attrs, :id))

      {:ok, {left_note, right_note}}
    end
  end

  @spec end_tick(t()) :: non_neg_integer()
  def end_tick(%__MODULE__{} = note), do: note.start_tick + note.duration_tick

  @spec put_manual_slice_flag(t(), slice_flag()) :: t()
  def put_manual_slice_flag(%__MODULE__{} = note, slice_flag) do
    slice_flag = normalize_slice_flag(slice_flag)
    extra = put_extra_manual_slice_flag(note.extra, slice_flag)
    %{note | slice_flag: slice_flag, extra: extra}
  end

  @spec manual_slice_flag(t()) :: slice_flag()
  def manual_slice_flag(%__MODULE__{} = note) do
    note.extra
    |> Map.get(:manual_slice_flag, Map.get(note.extra, "manual_slice_flag"))
    |> normalize_slice_flag()
  end

  @spec slice_start?(slice_flag()) :: boolean()
  def slice_start?({:on_start, slice_id}) when is_binary(slice_id), do: true
  def slice_start?(_slice_flag), do: false

  @spec slice_start_id(slice_flag()) :: slice_id() | nil
  def slice_start_id({:on_start, slice_id}) when is_binary(slice_id), do: slice_id
  def slice_start_id(_slice_flag), do: nil

  @spec manual_slice_start?(t()) :: boolean()
  def manual_slice_start?(%__MODULE__{} = note), do: slice_start?(manual_slice_flag(note))

  @spec manual_slice_end?(t()) :: boolean()
  def manual_slice_end?(%__MODULE__{} = note), do: manual_slice_flag(note) == :on_end

  defp put_extra_manual_slice_flag(extra, nil) do
    extra
    |> Map.delete(:manual_slice_flag)
    |> Map.delete("manual_slice_flag")
  end

  defp put_extra_manual_slice_flag(extra, slice_flag) do
    extra
    |> Map.delete("manual_slice_flag")
    |> Map.put(:manual_slice_flag, slice_flag)
  end

  defp pick_merge_value(left, right) do
    cond do
      right in [nil, ""] -> left
      true -> right
    end
  end

  defp normalize_slice_flag({:on_start, slice_id}) when is_binary(slice_id), do: {:on_start, slice_id}
  defp normalize_slice_flag(:on_end), do: :on_end
  defp normalize_slice_flag(nil), do: nil

  defp normalize_slice_flag(flag) when is_tuple(flag) do
    case Tuple.to_list(flag) do
      [on_start, slice_id] when on_start in [:on_start, "on_start"] and is_binary(slice_id) ->
        {:on_start, slice_id}

      _ ->
        nil
    end
  end

  defp normalize_slice_flag(flag) when flag in [:on_end, "on_end"], do: :on_end
  defp normalize_slice_flag(_flag), do: nil

  @doc false
  @spec preserve_single_note_slice_start?(slice_flag(), slice_flag()) :: boolean()
  def preserve_single_note_slice_start?(current_flag, repaired_flag)

  def preserve_single_note_slice_start?({:on_start, current_id}, :on_end)
      when is_binary(current_id) do
    true
  end

  def preserve_single_note_slice_start?(_current_flag, _repaired_flag), do: false
end
