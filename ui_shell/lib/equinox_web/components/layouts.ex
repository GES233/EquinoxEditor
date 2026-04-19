defmodule EquinoxWeb.Layouts do
  @moduledoc """
  该模块包含应用的布局和相关功能。
  """
  use EquinoxWeb, :html

  # 将 layouts/* 中的所有文件嵌入此模块。
  # 默认的 root.html.heex 文件包含应用程序的 HTML 框架，即 HTML 标头和其他静态内容
  embed_templates "layouts/*"
end
