# Custode lifecycle

Run lifecycle commands from the checkout that hosts the fleet. Never start Custode from a development worktree. Preserve the configured `CUSTODE_HOME` in every shell so the command reaches the intended installation.

## Install and start

Confirm the host has Elixir and OTP versions supported by the checkout, authenticated provider CLIs, and authenticated `gh`. Then:

```sh
export CUSTODE_HOME=/path/to/custode-state
mix deps.get
mix ecto.migrate
mix custode doctor
mix run --no-halt
```

The explicit migration makes schema work visible before boot; boot also runs pending migrations. `mix phx.server` is an equivalent foreground development entry point. The dashboard and MCP endpoint bind to loopback by default.

If doctor reports only the documented Claude failures on a Codex-only host, read the provider section in [troubleshooting.md](troubleshooting.md) before deciding whether that installation is usable.

## Update or restart safely

Before stopping the node, bootstrap the installation again, inspect executing turns and open gates, and decide pending gates when practical. A gate left open is durable and returns after boot.

1. Call the live `drain` operation or run `mix custode drain`. The reply only confirms that admission is paused and background draining started. It is not evidence that the server stopped.
2. Wait until the Custode process actually exits. Follow the feed while it remains available and confirm the service or foreground process has stopped; the MCP endpoint becoming unreachable is expected only after shutdown. If the feed records `drain_timeout`, stop the update. The queues remain paused. Resolve the stuck work and drain again, or use the documented queue-resume abort path only after the human chooses to abandon the restart. Do not pull source, change dependencies, or migrate while the old node is still running.
3. In the live checkout, update the source and dependencies, then run doctor
   before applying schema changes:

   ```sh
   git pull --ff-only
   mix deps.get
   mix custode doctor
   ```

4. Fix every doctor failure before changing the schema. Also apply the doctor-printed operator-skill command for each host where the package is missing. For a stale or modified package, inspect it and obtain the human's decision before using the printed `--force` command.
5. If doctor reports pending migrations, review the release or pull request's operating note and take a recoverable backup of `CUSTODE_HOME` when the change warrants one. Then run `mix ecto.migrate` and `mix custode doctor` again. Fix any new failure before continuing.
6. Do not start a second node against the same home. Start the node again with `mix run --no-halt` or the installation's existing service command.
7. Read the new `$CUSTODE_HOME/tmp/operator.token`, refresh the environment inherited by Claude Code or Codex, and restart or reconnect that host so it loads any updated skill package. The operator token is rewritten on every boot.
8. Invoke this skill again, call `operator_bootstrap`, and verify the retained `installation.id` before resuming work.

Use `CUSTODE_TAKEOVER=1` only to recover a genuinely wedged predecessor after confirming the old process is no longer serving the installation. It is not part of an ordinary restart.

## Migrations and repository changes

Do not edit the running checkout to develop an update. Route source changes through the routine serving `genagent/custode` as described in [self-maintenance.md](self-maintenance.md). Pull a reviewed, merged change into the live checkout only during the drained update sequence above.

Review repository changes and operating notes before applying migrations. Keep a recoverable backup of `CUSTODE_HOME` when the change warrants one.

## Uninstall

Uninstall removes durable fleet state. Do it only when the human explicitly requests it and after confirming each exact path.

1. Drain or otherwise stop the server.
2. Remove the intended `CUSTODE_HOME` and Custode checkout. Repository checkouts that the human supplied remain theirs.
3. Remove the `custode-operator` directory from the selected Claude and Codex skill homes.
4. Remove the saved MCP registrations:

   ```sh
   claude mcp remove custode --scope user
   codex mcp remove custode
   ```

Do not print, preserve in logs, or copy operator or routine tokens while cleaning up.
