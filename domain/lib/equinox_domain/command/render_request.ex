defmodule EquinoxDomain.Command.RenderRequest do
  @moduledoc """
  渲染请求——Compiler 的统一入口。

  无论来自预览（Window）还是已材料化的 Utterance，都先构造成 RenderRequest，
  Compiler 只认这一种类型。

  构造时自动完成：
  - 从 Track 查询 Note 本体
  - 切片 data_channels，并做 adopted-over-user 的分辨
  - 切片 TempoMap 中的 tempo_segments
  - 拉取 active_preset 的 declarations
  """

  alias EquinoxDomain.{
    Util.ID,
    Timeline.TempoMap,
    Timeline.Tick,
    Score.Note,
    Score.Track,
    Score.Utterance,
    Port.Declaration,
    Port.Channel,
    Port.Preset,
    LayerChunk
  }

  alias EquinoxDomain.Score.Slicer.Window

  @type t :: %__MODULE__{
          track_id: ID.t(Track),
          note_ids: [ID.t(Note)],
          notes: [Note.t()],
          time_range: {Tick.numeric_tick(), Tick.numeric_tick()},
          tempo_segments: [TempoMap.compiled_event()],
          data_slices: %{Channel.channel() => [LayerChunk.t()]},
          declarations: %{Channel.channel() => Declaration.t()}
        }

  use EquinoxDomain.Util.Object,
    keys: [
      :track_id,
      note_ids: [],
      notes: [],
      time_range: {0, 0},
      tempo_segments: [],
      data_slices: %{},
      declarations: %{}
    ]

  @doc """
  从 Window（预览路径）构建 RenderRequest。

  Window 未被材料化——如果 Track 上已有该时间窗口的 adopted 数据，
  会被合并进 data_slices。
  """
  @spec from_window(Window.t(), Track.t(), TempoMap.t()) :: {:ok, t()} | {:error, term()}
  def from_window(%Window{} = window, %Track{} = track, tempo_map) do
    time_range = {window.tick_start, window.tick_end}
    {t0, t1} = time_range

    with {:ok, notes} <- lookup_notes(track, window.note_ids),
         tempo_segs = TempoMap.slice(tempo_map, t0, t1),
         data_slices = slice_and_resolve(track, time_range),
         declarations = active_declarations(track) do
      new(
        track_id: track.id,
        note_ids: window.note_ids,
        notes: notes,
        time_range: time_range,
        tempo_segments: tempo_segs,
        data_slices: data_slices,
        declarations: declarations
      )
    end
  end

  @doc """
  从 Utterance（已材料化路径）构建 RenderRequest。

  Utterance 的材料化意味着其对应时间范围内一定存在 adopted 数据，
  data_slices 中 adopted 会覆盖同 channel 的 user 重叠区间。
  """
  @spec from_utterance(Utterance.t(), Track.t(), TempoMap.t()) :: {:ok, t()} | {:error, term()}
  def from_utterance(%Utterance{} = utterance, %Track{} = track, tempo_map) do
    time_range = {utterance.start_tick, utterance.start_tick + utterance.duration_tick}
    {t0, t1} = time_range

    with {:ok, notes} <- lookup_notes(track, utterance.note_ids),
         tempo_segs = TempoMap.slice(tempo_map, t0, t1),
         data_slices = slice_and_resolve(track, time_range),
         declarations = active_declarations(track) do
      new(
        track_id: track.id,
        note_ids: utterance.note_ids,
        notes: notes,
        time_range: time_range,
        tempo_segments: tempo_segs,
        data_slices: data_slices,
        declarations: declarations
      )
    end
  end

  # ---- helpers ----

  defp lookup_notes(%Track{notes: notes_map}, note_ids) do
    case Enum.reduce_while(note_ids, {:ok, []}, fn id, {:ok, acc} ->
           case Map.fetch(notes_map, id) do
             {:ok, note} -> {:cont, {:ok, [note | acc]}}
             :error -> {:halt, {:error, {:note_not_found, id}}}
           end
         end) do
      {:ok, notes} -> {:ok, Enum.reverse(notes)}
      {:error, _} = err -> err
    end
  end

  @doc false
  def slice_and_resolve(%Track{data_channels: channels}, {start_tick, end_tick}) do
    Map.new(channels, fn {channel, chunks} ->
      relevant =
        chunks
        |> Enum.filter(fn ch ->
          ch.start_tick < end_tick and ch.end_tick > start_tick
        end)
        |> clip_chunks(start_tick, end_tick)
        |> resolve_overlaps()

      {channel, relevant}
    end)
  end

  defp clip_chunks(chunks, range_start, range_end) do
    Enum.map(chunks, fn ch ->
      %{ch | start_tick: max(ch.start_tick, range_start), end_tick: min(ch.end_tick, range_end)}
    end)
  end

  defp resolve_overlaps(chunks) do
    {adopted, user} = Enum.split_with(chunks, &(&1.source == :adopted))
    adopted_ranges = Enum.map(adopted, &{&1.start_tick, &1.end_tick})

    user_kept =
      Enum.reject(user, fn uc ->
        Enum.any?(adopted_ranges, fn {a0, a1} ->
          uc.start_tick < a1 and a0 < uc.end_tick
        end)
      end)

    adopted ++ user_kept
  end

  defp active_declarations(%Track{presets: _presets, active_preset: nil}), do: %{}

  defp active_declarations(%Track{presets: presets, active_preset: name}) do
    case Map.fetch(presets, name) do
      {:ok, %Preset{declarations: decls}} -> decls
      :error -> %{}
    end
  end
end
