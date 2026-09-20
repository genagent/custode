import Config

config :custode,
  # No cron entries in tests: nothing scheduled, nothing auto-started.
  routines: [],
  # No executing queues in tests: jobs insert but never run, so a test can
  # NEVER make a paid claude call by accident.
  oban_queues: [],
  # The routine scheduler's timer stays disarmed in tests (like the empty
  # executing queues): a test that puts routines into env must not have the
  # app-level scheduler fire them on a wall-clock minute. Its own tests drive
  # injected instances directly.
  scheduler_autostart: false,
  # The lease reconciler's cron line stays out of the test crontab: the Cron
  # plugin inserts rows at every matching minute even with no executing
  # queues, and a */15 insert landing inside a test's unfiltered Oban.Job
  # count assertion is the "passes alone, fails on the third run" class.
  # Its tests set the env themselves and call the worker directly (#430).
  workspace_lease_reconcile_cron: false,
  # Same reasoning for the aging re-notifier (#446).
  aging_cron: false,
  # ...and for the usage probe, which would otherwise spawn a real claude (#458)
  usage_probe_cron: false,
  desktop_notifications: false,
  # the suite spawns no claude; leave the test VM's environment alone
  claude_env: %{},
  # No network in tests: repo overviews come from the fake fetcher.
  github_fetcher: Custode.Test.FakeGitHubFetcher,
  feed_path: "tmp/test/feed.jsonl",
  # A fixed port means two checkouts cannot run the suite at once (the second
  # boot fails with :eaddrinuse). A second worktree sets this to its own port.
  mcp_port: String.to_integer(System.get_env("CUSTODE_TEST_MCP_PORT", "6171")),
  # test-owned MCP config files: the suite must never touch a live server's
  mcp_config_dir: "tmp/test/mcp"

config :custode, CustodeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4647],
  server: false

config :custode, Custode.Repo,
  database: "tmp/test/custode_test.db",
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
