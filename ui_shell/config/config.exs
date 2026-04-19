# 此文件负责借助 Config 模块配置您的应用程序及其依赖项。
#
# 此配置文件会在加载任何依赖项之前加载，并且仅限于此项目。

# 通用应用配置
import Config

config :equinox_ui_shell,
  generators: [timestamp_type: :utc_datetime],
  graph_translator: EquinoxUiShell.SvelteFlowGraphTranslator

# 不显示报警（因为 Windows 需要管理员权限使用 symlink）
config :phoenix_live_view, :colocated_js, disable_symlink_warning: true

# 配置端点
config :equinox_ui_shell, EquinoxWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EquinoxWeb.ErrorHTML, json: EquinoxWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Equinox.PubSub,
  live_view: [signing_salt: "0nzCiDAR"]

# 配置 Elixir 日志
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# 在 Phoenix 中使用 Jason 来解析 JSON
config :phoenix, :json_library, Jason

# 导入特定环境的配置。此配置必须保留在本文件的末尾，
# 以便覆盖上面定义的配置。
import_config "#{config_env()}.exs"
