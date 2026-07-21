import Config

config :custode,
  # No cron entries in tests: nothing scheduled, nothing auto-started.
  routines: [],
  # No executing queues in tests: jobs insert but never run, so a test can
  # NEVER make a paid claude call by accident.
  oban_queues: [],
  desktop_notifications: false,
  # No network in tests: repo overviews come from the fake fetcher.
  github_fetcher: Custode.Test.FakeGitHubFetcher,
  feed_path: "tmp/test/feed.jsonl",
  mcp_port: 6171

config :custode, CustodeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4647],
  server: false

config :custode, Custode.Repo,
  database: "tmp/test/custode_test.db",
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
