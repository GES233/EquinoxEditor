defmodule EquinoxWeb.Router do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/api/session" do
    project_id = EquinoxWeb.Demo.project_id()

    case Neumu.snapshot(project_id) do
      {:ok, _} ->
        json(conn, 200, %{
          project_id: project_id,
          token: Phoenix.Token.sign(EquinoxWeb.Endpoint, "project", project_id)
        })

      {:error, _} ->
        json(conn, 503, %{error: "演示工程尚未打开"})
    end
  end

  get "/" do
    path = Application.app_dir(:equinox_web, "priv/static/index.html")

    if File.regular?(path) do
      conn |> put_resp_content_type("text/html") |> send_file(200, path)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(503, "请先在 apps/equinox_web/assets 执行 npm run build，或使用 Vite 开发地址。")
    end
  end

  match _ do
    send_resp(conn, 404, "未找到页面")
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
