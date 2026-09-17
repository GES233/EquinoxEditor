import Config

config :neume, voicebank_provider: NeumeOpuDs.Voicebank.Provider

config :phoenix, :json_library, Jason

# 只有显式启动 UI 才监听本机端口；普通 umbrella 测试不打开演示工程。
config :equinox_web, demo: System.get_env("EQUINOX_WEB_SERVER") == "1"

config :equinox_web, EquinoxWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  server: System.get_env("EQUINOX_WEB_SERVER") == "1",
  http: [ip: {127, 0, 0, 1}, port: 4000],
  url: [host: "localhost", port: 4000],
  check_origin: [
    "http://127.0.0.1:4000",
    "http://localhost:4000",
    "http://127.0.0.1:5173",
    "http://localhost:5173"
  ],
  secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
  pubsub_server: EquinoxWeb.PubSub
