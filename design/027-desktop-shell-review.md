# 027: Keep LiveView; defer an optional desktop shell

Status: evidence review for #576, 2026-10-04. Inspected baseline: `4ebb581`.
No shell was built or run, and no comparative measurements were collected.

## Decision

Keep the LiveView console as the main interface. Start with Safari Add to
Dock for a dedicated macOS window when the operator wants app identity.
Retain #576 as a deferred comparison, scheduled only after reliable daily use
reveals at least two concrete desktop needs still unmet by the shipped web
and notification paths. Repository gaps are candidates to observe, not two
user needs already demonstrated. Do not adopt a desktop dependency now.

If that trigger is met, compare one thin Tauri client against the same console
in a Safari web app. Connect to the existing independently running service.
ElixirKit is relevant to a later packaging decision; starting a bundled BEAM
inside the shell is outside the first experiment. Native widgets require a
separate case and a maintained implementation path.

## Shipped baseline and remaining candidates

| Need | Current path | What a later comparison must establish |
|---|---|---|
| Search and navigation | `Console.Commands`, `CommandPalette` and layout hooks ship Cmd/Ctrl+K search; Shift+Cmd/Ctrl+K opens the manager | A global shortcut must save real foreground/navigation effort beyond these in-window shortcuts |
| Desktop attention | `Feed.Notify` uses terminal-notifier on macOS when present, with osascript fallback; ntfy handles configured phone delivery | A shell indicator must improve actual attention reliability, not duplicate another channel |
| Notification destination | terminal-notifier `-open` and ntfy click use `Ntfy.dashboard_url/1`, reaching `/console/<agent>` or the base URL | These are subject links, not an exact gate/ask ID. Verify the required item route and stale-item behavior before crediting the shell |
| Direct conversation and browser access | `/agents/:id/conversation`, `/custode` and the console stay normal LiveView routes | Opening a destination must remain navigation, without starting work or accepting an approval |
| Work lifetime | BEAM/Oban execution is separate from browser windows | Closing or quitting the client must leave scheduled and executing work intact |

The source contains no implemented website push/service-worker notification
path. Safari notification badges therefore cannot be credited to Custode
merely by adding its URL to the Dock. The osascript fallback also cannot be
credited with terminal-notifier's URL-open behavior. Sink-based tests prove
messages and URLs are constructed, not that macOS notification clicks work
in a particular installed application.

## Primary-source review

Sources were checked on 2026-10-04; compatibility claims below are limited to
what their maintainers document.

- **Safari web apps.** Apple documents Add to Dock on macOS Sonoma 14 or later,
  a separate app identity with Dock/Spotlight opening, and optional login-item
  launch. The app has separate website data from Safari. Dock notification
  badges require a website that sends notifications and permission granted
  inside the web app. This provides a low-cost identity baseline, not backend
  installation or a count of Custode's attention resolver.
  [Apple support](https://support.apple.com/en-us/104996).
- **Tauri 2.** Its core owns windows, tray and OS integration; the webview
  renders HTML/CSS/JavaScript through the platform engine (WKWebView on
  macOS). Reusing LiveView is plausible, but platform behavior still needs
  testing. [Process model](https://v2.tauri.app/concept/process-model/).
  Maintained documentation covers [global shortcuts](https://v2.tauri.app/plugin/global-shortcut/),
  [notifications](https://v2.tauri.app/plugin/notification/) and
  [deep links](https://v2.tauri.app/plugin/deep-linking/). The deep-link guide
  requires validating incoming URLs and notes that macOS testing needs an
  installed bundled application. A development-window demonstration alone
  cannot establish notification routing.
- **ElixirKit.** The maintainer repository links a Phoenix LiveView/Tauri
  guide. Its example starts Elixir from Rust, sets PubSub `on_exit` to stop
  Elixir, and exits Tauri when the Elixir command returns. Those example
  choices couple lifetimes and conflict with a client whose quit must leave
  the fleet running. The guide separately covers releases, native-code
  signing and notarization; those are additional packaging work rather than
  benefits supplied by a webview.
  [Repository](https://github.com/livebook-dev/elixirkit),
  [guide](https://elixirkit.hexdocs.pm/tauri.html).
- **Livebook precedent.** Its desktop source exists in
  [rel/app](https://github.com/livebook-dev/livebook/tree/main/rel/app), and
  the ElixirKit guide identifies Livebook as its origin. This is a reuse
  precedent, not proof that Custode's providers, subprocesses, filesystem or
  service lifetime work in a shell.
- **LiveView Native.** The original repository is archived, read-only since
  2026-02-10. Its README requires platform-specific templates; it does not
  turn daisyUI markup into native widgets. No maintained replacement was
  established by this bounded review. Adoption remains unjustified.
  [Original repository](https://github.com/liveview-native/live_view_native).

- **Elixir Desktop.** Its current README documents wx, JSON/mobile and
  browser backends for LiveView, with window/menu/notification integration.
  Its roadmap still lists desktop installers, code signing and auto-updates
  as work items. This remains an alternative, with Custode toolchain and
  service-lifetime compatibility untested; it is not selected for the first
  comparison. [Maintainer README](https://raw.githubusercontent.com/elixir-desktop/desktop/main/README.md).

## Client and service lifetime contract

A later spike must keep these responsibilities distinct:

| Event | Client responsibility | Service responsibility |
|---|---|---|
| Open or foreground | Connect to the configured service, show connection state and current attention | Keep scheduling and admission under existing policy |
| Close window or quit app | Disconnect; no implicit pause, drain, cancellation or service shutdown | Continue admitted work and schedules |
| Service down/restart | Show disconnected state, reconnect and refresh current facts; do not replay writes | Recover through existing durable records and normal readiness |
| Explicit stop service | Invoke the existing authorized shared drain/shutdown operation and report admission separately from completion | Own admission closure, drain, timeout and shutdown |
| Sleep/wake | Reconnect, refresh facts and report unresolved connection failures | Retain current scheduler/provider lifecycle semantics |
| Client update | Restart only the client | Continue service; a bundled-service update needs its own future lifecycle decision |

Desktop commands that affect work call existing shared operations or their
MCP surfaces with current authentication and capabilities. Native IPC and
custom URLs grant no extra authority. An item URL navigates to a validated
identity; it does not approve a gate. Remote browser/phone access and stable
subject identity survive client exit. Do not copy attention rules into Rust.

The closed #573 subprocess repair and #574 ownership audit are relevant
service evidence; neither proves a new host's lifecycle. Bundling a release,
service installation, CLI discovery, provider login, Git/SSH access, working
directories and service updates stay separate decisions if packaging is later
proposed.

## Bounded comparison when the trigger is met

Record the two observed unmet needs, host/OS versions and existing setup
before choosing one candidate. Use the unchanged console and existing service
for both Safari and the shell. Demonstrate a resolver-derived attention
indicator, an exact-item notification destination and a global shortcut.
Verify cold and warm opening, window close and app quit while work continues,
service restart reconnect, and sleep/wake. Keep approvals deliberate.

Compare actual launch/navigation effort, notification delivery and click
outcomes, keyboard/focus/accessibility behavior, and measured idle CPU/memory
on the same host. Record build, install, signing, update and maintenance work.
Mark failures and unknowns explicitly. No estimated memory savings, latency
improvement, offline operation or notification reliability counts as observed
benefit.

Choose keep-web unless the two unmet needs are resolved with a maintenance
cost the operator accepts. Add-shell is a separate implementation decision
supported by those observations. Investigate-native needs an interaction the
webview cannot satisfy and a maintained client path. #576 stays open: this
review refreshes its baseline and constraints, and does not complete its
required actual comparison.
