defmodule CustodeWeb.Layouts do
  @moduledoc """
  The root layout. Styling is daisyUI 5 + the Tailwind 4 browser build, both
  from CDN, and the LiveView client comes from the hex packages' vendored JS
  -- no node, no asset pipeline. The page needs internet access on first load
  for the two CDN tags; everything else is local.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="paper">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>custode</title>
        <%!-- Inline, so no page load asks the router for /favicon.ico or an
              apple-touch-icon and logs three 404s. There is no asset pipeline
              to put a file in. --%>
        <link
          rel="icon"
          href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='7' fill='%231f2937'/%3E%3Ccircle cx='16' cy='16' r='7' fill='none' stroke='%23fbbf24' stroke-width='3'/%3E%3C/svg%3E"
        />
        <link
          rel="apple-touch-icon"
          href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' fill='%231f2937'/%3E%3Ccircle cx='16' cy='16' r='7' fill='none' stroke='%23fbbf24' stroke-width='3'/%3E%3C/svg%3E"
        />
        <%!-- Before first paint, so the page never flashes the wrong theme:
              the operator's remembered choice, else what the OS prefers. --%>
        <script>
          (() => {
            const saved = localStorage.getItem("custode-theme");
            const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
            document.documentElement.dataset.theme = saved || (dark ? "ink" : "paper");
          })();
        </script>
        <link href="https://cdn.jsdelivr.net/npm/daisyui@5" rel="stylesheet" type="text/css" />
        <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
        <.theme_css />
        <script src="/vendor/phoenix/phoenix.min.js"></script>
        <script src="/vendor/phoenix_live_view/phoenix_live_view.min.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", () => {
            const csrf = document.querySelector("meta[name='csrf-token']").content;
            const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrf}
            });
            liveSocket.connect();
            window.liveSocket = liveSocket;
          });

          // Cmd/Ctrl+K talks to custode from any page (#451); Escape there
          // goes back. A full navigation on purpose: it works from pages in
          // another live session, and it is rare.
          window.addEventListener("keydown", (event) => {
            const onRoot = window.location.pathname === "/custode";
            if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
              event.preventDefault();
              if (!onRoot) window.location.assign("/custode");
            } else if (event.key === "Escape" && onRoot) {
              if (window.history.length > 1) window.history.back();
              else window.location.assign("/console");
            }
          });
        </script>
        <style>
          /* agent-output markdown (journal tables and friends) */
          .agent-md table { border-collapse: collapse; margin: 0.5rem 0; font-size: 0.8rem; }
          .agent-md th, .agent-md td { border: 1px solid color-mix(in oklab, currentColor 20%, transparent); padding: 0.2rem 0.5rem; text-align: left; }
          .agent-md th { font-weight: 600; }
          .agent-md code { font-size: 0.8em; background: color-mix(in oklab, currentColor 10%, transparent); padding: 0.1em 0.3em; border-radius: 0.25rem; }
          .agent-md pre { overflow-x: auto; background: color-mix(in oklab, currentColor 8%, transparent); padding: 0.5rem; border-radius: 0.375rem; margin: 0.5rem 0; }
          .agent-md pre code { background: none; padding: 0; }
          .agent-md ul, .agent-md ol { padding-left: 1.25rem; margin: 0.25rem 0; }
          .agent-md ul { list-style: disc; }
          .agent-md ol { list-style: decimal; }
          .agent-md p { margin: 0.25rem 0; }
          .agent-md h1, .agent-md h2, .agent-md h3 { font-weight: 600; margin: 0.5rem 0 0.25rem; }
          .agent-md blockquote { border-left: 3px solid color-mix(in oklab, currentColor 25%, transparent); padding-left: 0.6rem; opacity: 0.85; }
        </style>
      </head>
      <body class="min-h-screen bg-base-200">
        {@inner_content}
      </body>
    </html>
    """
  end

  @doc """
  The design session's visual language (design/ui/2026-07-25-design-session)
  as two daisyUI 5 themes: `paper`, the light mockups, and `ink`, the dark
  `custode-root.png`. Tokens and nothing else, so every page that uses the
  semantic classes (`bg-base-100`, `text-warning`, `btn-primary`) wears it
  with no markup change. One meaning per colour (guides/ui-hierarchy.md):
  error is blocked on you, warning wants you, info is working, neutral is the
  near-black secondary button, primary is the one thing to press.

  A component and not inline in `root/1` so the fixture preview, which has no
  root layout, can wear the same tokens.
  """
  def theme_css(assigns) do
    ~H"""
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link
      href="https://fonts.googleapis.com/css2?family=Fira+Sans:ital,wght@0,400;0,500;0,600;1,400&family=JetBrains+Mono:wght@400;500;700&display=swap"
      rel="stylesheet"
    />
    <style type="text/tailwindcss">
      @theme {
        --font-sans: "Fira Sans", ui-sans-serif, system-ui, sans-serif;
        --font-mono: "JetBrains Mono", ui-monospace, "SF Mono", Menlo, monospace;
      }
    </style>
    <style>
      [data-theme="paper"] {
        color-scheme: light;
        --color-base-100: #ffffff;
        --color-base-200: #fbf9f4;
        --color-base-300: #e9e4d8;
        --color-base-content: #1c1a17;
        --color-primary: #4f46e5;
        --color-primary-content: #ffffff;
        --color-secondary: #6b6558;
        --color-secondary-content: #ffffff;
        --color-accent: #b8860b;
        --color-accent-content: #ffffff;
        --color-neutral: #1c1a17;
        --color-neutral-content: #fbf9f4;
        --color-info: #0f766e;
        --color-info-content: #ffffff;
        --color-success: #15803d;
        --color-success-content: #ffffff;
        --color-warning: #b8860b;
        --color-warning-content: #ffffff;
        --color-error: #dc2626;
        --color-error-content: #ffffff;
      }

      [data-theme="ink"] {
        color-scheme: dark;
        --color-base-100: #201f1b;
        --color-base-200: #161511;
        --color-base-300: #34322b;
        --color-base-content: #ece8dc;
        --color-primary: #e8c55a;
        --color-primary-content: #1c1a12;
        --color-secondary: #a39d8c;
        --color-secondary-content: #161511;
        --color-accent: #e8c55a;
        --color-accent-content: #1c1a12;
        --color-neutral: #ece8dc;
        --color-neutral-content: #161511;
        --color-info: #5eead4;
        --color-info-content: #10211f;
        --color-success: #6ee7a0;
        --color-success-content: #10211a;
        --color-warning: #e8c55a;
        --color-warning-content: #1c1a12;
        --color-error: #f87171;
        --color-error-content: #2a1010;
      }

      [data-theme="paper"], [data-theme="ink"] {
        --radius-selector: 0.5rem;
        --radius-field: 0.5rem;
        --radius-box: 0.75rem;
        --border: 1px;
        --depth: 0;
        --noise: 0;
      }

      /* the mockups draw hairlines, not shadows */
      [data-theme="paper"] .shadow-sm, [data-theme="ink"] .shadow-sm {
        box-shadow: none;
        border: 1px solid var(--color-base-300);
      }
    </style>
    """
  end

  @doc """
  The live layout every dashboard page renders inside (#337).

  It exists for one reason: the flash. The root layout above is rendered
  once, by the plug pipeline, and never again -- LiveView's docs are explicit
  that it "has no LiveView related functionality". Every `put_flash/3` in
  this app fires from a `handle_event`, long after that render, so a flash
  container in the root `<body>` would never show a single one of them. This
  layout IS inside the diff, so it updates.
  """
  def app(assigns) do
    ~H"""
    <.flash_group flash={@flash} />
    {@inner_content}
    """
  end

  @doc """
  The flash messages, as a toast in the top-right corner.

  Click dismisses: `lv:clear-flash` is LiveView's own event, so no page needs
  a handler for it.
  """
  def flash_group(assigns) do
    ~H"""
    <div class="toast toast-top toast-end z-50">
      <.flash kind={:info} message={Phoenix.Flash.get(@flash, :info)} />
      <.flash kind={:error} message={Phoenix.Flash.get(@flash, :error)} />
    </div>
    """
  end

  attr(:kind, :atom, required: true)
  attr(:message, :string, default: nil)

  defp flash(assigns) do
    ~H"""
    <div
      :if={@message}
      id={"flash-#{@kind}"}
      role="alert"
      class={[
        "alert cursor-pointer max-w-md whitespace-pre-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}
      phx-click="lv:clear-flash"
      phx-value-key={@kind}
    >
      <span>{@message}</span>
    </div>
    """
  end
end
