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
      </head>
      <body class="min-h-screen bg-base-200">
        {@inner_content}
      </body>
    </html>
    """
  end
end
