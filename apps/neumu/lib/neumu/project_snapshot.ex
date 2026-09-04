defmodule Neumu.ProjectSnapshot do
  @moduledoc """
  工程权威状态的只读投影，供 UI 展示。

  投影只含可序列化 plain data：轨道、音符、mix/globals 与 History cursor
  （`history_pin`）。不含 PID、worker、`Coconut.Session`、Oi compiled graph
  等运行时对象。快照与生成它的 `history_pin` 一致；UI 收到
  `{:project_changed, project_id, history_pin}` 后重新查询。
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

  @typedoc "轨道投影；`voicebank` 是工程保存的声库签名 plain map。"
  @type track :: %{
          id: Track.track_id(),
          name: String.t() | nil,
          voicebank: Coconut.Project.voicebank() | nil,
          mix: TrackConfig.mix(),
          globals: map(),
          notes: [note()]
        }

  @typedoc "工程只读快照。"
  @type t :: %{
          project_id: Neume.RenderJob.project_id(),
          history_pin: History.node_id(),
          tracks: [track()]
        }

  @doc "从 `Neume.MultiTrack` 权威值投影当前 History cursor 下的工程状态。"
  @spec build(Neume.MultiTrack.t(), Neume.RenderJob.project_id()) :: t()
  def build(%Neume.MultiTrack{} = multi_track, project_id) do
    workspace = Coconut.workspace(multi_track.session)

    %{
      project_id: project_id,
      history_pin: History.current(multi_track.session.history).node_id,
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
      notes: track |> Track.view() |> Enum.map(&project_note/1)
    }
  end

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
