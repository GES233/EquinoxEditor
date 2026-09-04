defmodule Neume.TrackConfig do
  @moduledoc """
  Neume 持久化在 Coconut `Track.extras` 中的逐轨宿主配置。

  Coconut 只保存 plain data，不理解声库、混音或运行时语义。
  """

  alias Coconut.Edit.Track

  @namespace :neume
  @default_mix %{gain: 1.0, pan: 0.0, mute: false}

  @type mix :: %{gain: float(), pan: float(), mute: boolean()}

  @spec voicebank(Track.t()) :: Coconut.Project.voicebank() | nil
  def voicebank(%Track{extras: extras}), do: get_in(extras, [@namespace, :voicebank])

  @spec put_voicebank(Track.t(), Coconut.Project.voicebank() | nil) :: Track.t()
  def put_voicebank(%Track{} = track, nil), do: track

  def put_voicebank(%Track{} = track, signature) do
    %{track | extras: put_in(track.extras, [Access.key(@namespace, %{}), :voicebank], signature)}
  end

  @spec mix(Track.t()) :: mix()
  def mix(%Track{extras: extras}) do
    @default_mix
    |> Map.merge(get_in(extras, [@namespace, :mix]) || %{})
    |> normalize_mix()
  end

  @spec put_mix(Track.t(), map()) :: {:ok, Track.t()} | {:error, term()}
  def put_mix(%Track{} = track, attrs) when is_map(attrs) do
    mix = Map.merge(mix(track), attrs)

    case validate_mix(mix) do
      :ok ->
        extras = put_in(track.extras, [Access.key(@namespace, %{}), :mix], mix)
        {:ok, %{track | extras: extras}}

      {:error, _} = error ->
        error
    end
  end

  def put_mix(_track, attrs), do: {:error, {:invalid_mix, attrs}}

  @spec validate_mix(map()) :: :ok | {:error, term()}
  def validate_mix(%{gain: gain, pan: pan, mute: mute})
      when is_number(gain) and gain >= 0 and is_number(pan) and pan >= -1 and pan <= 1 and
             is_boolean(mute),
      do: :ok

  def validate_mix(value), do: {:error, {:invalid_mix, value}}

  defp normalize_mix(mix) do
    %{gain: mix.gain * 1.0, pan: mix.pan * 1.0, mute: mix.mute}
  end
end
