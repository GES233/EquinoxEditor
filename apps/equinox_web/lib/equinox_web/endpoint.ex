defmodule EquinoxWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :equinox_web

  socket("/socket", EquinoxWeb.UserSocket,
    websocket: true,
    longpoll: false
  )

  plug(Plug.Static,
    at: "/",
    from: :equinox_web,
    only: ~w(assets favicon.ico)
  )

  plug(EquinoxWeb.Router)
end
