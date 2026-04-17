defmodule EquinoxWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  Most complex UI is handled by Svelte via LiveView Hooks. This module only
  keeps absolute minimal Phoenix conveniences (like `.icon`).
  """
  use Phoenix.Component

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in your `assets/css/app.css`.

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  # TODO: define title component.

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
