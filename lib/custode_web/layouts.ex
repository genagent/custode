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
    <html lang="en" data-theme="dim">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>custode</title>
        <link href="https://cdn.jsdelivr.net/npm/daisyui@5" rel="stylesheet" type="text/css" />
        <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
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
end
