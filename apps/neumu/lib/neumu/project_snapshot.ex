defmodule Neumu.ProjectSnapshot do
  @moduledoc """
  工程权威状态的只读投影，供 UI 展示。

  投影只含可序列化 plain data：轨道、音符、存活 pin（`pins`）、
  mix/globals、拍号事件与 History cursor（`history_pin` 及
  `can_undo`/`can_redo`）。不含 PID、worker、`Coconut.Session`、Oi
  compiled graph 等运行时对象。快照与生成它的 `history_pin` 一致；UI
  收到 `{:project_changed, project_id, history_pin}` 后重新查询。
  """

  alias Coconut.Edit.{History, Track}
  alias Coconut.Score.Key
  alias Neume.TrackConfig

  @typedoc "音符投影；`pitch` 为精确 MIDI 值（小数微分音为十进制字符串），`nil` 表示无音高。"
  @type note :: %{
          id: term(),
          start_tick: integer(),
          end_tick: integer(),
          pitch: number() | String.t() | nil,
          lyric: String.t() | nil,
          annotation: String.t() | nil,
          metadata: %{binary() => term()}
        }

  @typedoc """
  存活 pin 投影（plain data）：patch id、channel、anchor 与 payload。

  `anchor` 目前恒为 ordinal 形：`%{type: :ordinal, refs: [note_id],
  at_version: version}`；`payload` 为挂载时的 plain data（pitch 点列、
  Bezier plain map 或时长下标列）。
  """
  @type pin :: %{
          id: Coconut.Util.ID.t(),
          channel: atom(),
          anchor: map(),
          payload: term()
        }

  @typedoc "轨道投影；`voicebank` 是工程保存的声库签名 plain map。"
  @type track :: %{
          id: Track.track_id(),
          name: String.t() | nil,
          voicebank: Coconut.Project.voicebank() | nil,
          mix: TrackConfig.mix(),
          globals: map(),
          notes: [note()],
          pins: [pin()]
        }

  @typedoc "工程只读快照。"
  @type t :: %{
          project_id: Neume.RenderJob.project_id(),
          history_pin: History.node_id(),
          can_undo: boolean(),
          can_redo: boolean(),
          time_sigs: [Coconut.Score.TimeSig.time_sig_event()],
          tracks: [track()]
        }

  @doc "从 `Neume.MultiTrack` 权威值投影当前 History cursor 下的工程状态。"
  @spec build(Neume.MultiTrack.t(), Neume.RenderJob.project_id()) :: t()
  def build(%Neume.MultiTrack{} = multi_track, project_id) do
    history = multi_track.session.history
    workspace = Coconut.workspace(multi_track.session)

    %{
      project_id: project_id,
      history_pin: History.current(history).node_id,
      can_undo: history.cursor > history.base_seq,
      can_redo: history.cursor < history.seq,
      time_sigs: workspace.time_sigs,
      tracks:
        workspace.tracks
        |> Enum.sort_by(fn {track_id, _track} -> track_id end)
        |> Enum.map(fn {_track_id, track} -> project_track(track) end)
    }
  end

  defp project_track(%Track{} = track) do
    %{
      id: track.id,
      name: track.name,
      voicebank: TrackConfig.voicebank(track),
      mix: TrackConfig.mix(track),
      globals: TrackConfig.globals(track),
      notes: track |> Track.view() |> Enum.map(&project_note/1),
      pins: Enum.map(track.patches, &project_pin/1)
    }
  end

  # pin 投影只留 plain data：Tamale patch 的 digest/内部结构不透出。
  defp project_pin(%Coconut.Edit.Patch{} = patch) do
    %{
      id: patch.id,
      channel: patch.channel,
      anchor: project_anchor(patch.anchor),
      payload: patch.patch.payload
    }
  end

  defp project_anchor(%Tamale.Anchor.Ordinal{refs: refs, at_version: version}),
    do: %{type: :ordinal, refs: refs, at_version: version}

  # Neume 只挂载 ordinal 锚；其他锚型兜底一个不携带内部结构的占位投影。
  defp project_anchor(%mod{}), do: %{type: mod |> Module.split() |> List.last()}

  defp project_note({note_id, note, {start_tick, end_tick}}) do
    %{
      id: note_id,
      start_tick: start_tick,
      end_tick: end_tick,
      pitch: pitch(note.key),
      lyric: note.lyric,
      annotation: note.annotation,
      metadata: note.metadata
    }
  end

  # canonical 投影保持精确值：整数 MIDI 保持整数，微分音保持十进制字符串。
  defp pitch(nil), do: nil

  defp pitch(%_{} = key) do
    case Key.to_canonical(key) do
      %{midi: midi} -> midi
      other -> other
    end
  end
end
