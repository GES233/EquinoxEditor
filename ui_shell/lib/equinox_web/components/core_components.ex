defmodule EquinoxWeb.CoreComponents do
  @moduledoc """
  提供核心 UI 部件。

  ~~第一眼看上去，这个模块看上去有些令人发怵，但是它的目标是为你的应用提供核心的「积木」，
  像是模态框、表格以及表单。~~好了，现在复杂组件交给 Svelte 了，其经由 LiveView 钩子而与后端连接。

  该模块仅提供一些最基本的最小化的 Phoenix 便捷功能（比方说 `.icon`）。
  """
  use Phoenix.Component

  @doc """
  渲染一个 [Heroicon](https://heroicons.com) 图标。

  Heroicon 的图标一般存在三种风格——轮廓（outline）、实心（solid）
  以及迷你（mini）。默认的风格是轮廓，对于实心以及小号的，可能需要
  `-solid` 以及 `-mini` 后缀。

  你可以通过设置宽高以及背景颜色来定制化图标的大小和颜色。

  图标从 `deps/heroicons` 目录提取，并由插件在 `assets/vendor/heroicons.js`
  中捆绑到编译好的 app.css 中。

      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  # TODO: Add title component.
end
