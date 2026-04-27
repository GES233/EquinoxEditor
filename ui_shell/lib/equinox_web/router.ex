defmodule EquinoxWeb.Router do
  use EquinoxWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {EquinoxWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", EquinoxWeb do
    pipe_through(:browser)

    live("/", EditorLive, :index)
  end

  # 其他 scope 可使用自定义的堆栈。
  # scope "/api", EquinoxWeb do
  #   pipe_through :api
  # end

  # 在开发中启用 LiveDashboard
  if Application.compile_env(:equinox_ui_shell, :dev_routes) do
    # 如果想在生产环境中使用 LiveDashboard，则应进行身份验证，且允许管理员访问。
    # 如果应用尚未设置仅限管理员访问的部分，则可以使用 Plug.BasicAuth
    # 设置一些基本身份验证，只要也部署了 SSL（无论如何都应该使用）。
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: EquinoxWeb.Telemetry)
    end
  end
end
