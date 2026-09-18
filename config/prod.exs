import Config

# Digested static assets, produced by `mix assets.deploy`.
config :khymeia, KhymeiaWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Khymeia is a local daemon served over plain HTTP on the loopback
# interface, so there is no TLS / HSTS configuration here.

config :logger, level: :info
