defmodule EquinoxWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :equinox_ui_shell

  # Session 将在 cookie 中保存并被签名，这意味着它的内容可以被阅读
  # 却无法被篡改。 如果你想要加密的话可以设置 :encryption_salt 。
  @session_options [
    store: :cookie,
    key: "_equinox_key",
    signing_salt: "JKUH5R/o",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  # 在生产环境下，如果你在运行 phx.digest 你应该把 gzip 设为真。
  #
  # 当代码重新加载被禁用时（例如生产环境），将启用 "gzip"
  # 选项来提供通过运行 "phx.digest" 生成的压缩静态文件。
  plug(Plug.Static,
    at: "/",
    from: :equinox_ui_shell,
    gzip: not code_reloading?,
    only: EquinoxWeb.static_paths(),
    raise_on_missing_only: code_reloading?
  )

  # 代码重载能够在你的端点的 :code_reloader 配置被显式地启用。
  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(EquinoxWeb.Router)
end
