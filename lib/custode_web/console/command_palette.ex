defmodule CustodeWeb.Console.CommandPalette do
  @moduledoc "Searchable command menu for the console."

  use Phoenix.Component

  attr(:open, :boolean, required: true)
  attr(:query, :string, required: true)
  attr(:commands, :list, required: true)

  def command_palette(assigns) do
    ~H"""
    <div
      :if={@open}
      id="command-palette"
      phx-hook="CommandPalette"
      role="dialog"
      aria-modal="true"
      aria-labelledby="command-palette-title"
      class="fixed inset-0 z-50 flex items-start justify-center bg-neutral/40 px-4 pt-[10vh]"
    >
      <button
        type="button"
        aria-label="Close command menu"
        phx-click="command_close"
        class="absolute inset-0 cursor-default"
      ></button>
      <section class="relative w-full max-w-2xl overflow-hidden rounded-box border border-base-300 bg-base-100 shadow-2xl">
        <div class="border-b border-base-300 p-3">
          <div class="mb-2 flex items-center gap-2 text-xs text-base-content/50">
            <h2 id="command-palette-title" class="font-bold uppercase tracking-widest text-base-content/70">
              Commands
            </h2>
            <span class="ml-auto">Ask <kbd class="kbd kbd-xs">⇧⌘K</kbd></span>
            <span>Close <kbd class="kbd kbd-xs">esc</kbd></span>
          </div>
          <form id="command-search" phx-change="command_search" phx-submit="command_search">
            <label for="command-query" class="mb-1 block text-sm font-medium">Search commands</label>
            <input
              id="command-query"
              data-command-input
              type="search"
              name="q"
              value={@query}
              autocomplete="off"
              aria-describedby="command-search-help"
              class="input input-ghost w-full px-1 text-base focus:outline-none"
            />
            <p id="command-search-help" class="mt-1 text-xs text-base-content/60">Search subjects, attention, results and actions.</p>
          </form>
        </div>
        <div role="listbox" aria-label="commands" class="max-h-[60vh] overflow-y-auto p-2">
          <p :if={@commands == []} class="p-4 text-sm text-base-content/50">No commands match.</p>
          <button
            :for={{command, index} <- Enum.with_index(@commands)}
            type="button"
            role="option"
            aria-selected={index == 0 && "true"}
            data-command-option
            phx-click="command_select"
            phx-value-id={command.id}
            class="flex w-full items-center gap-3 rounded-lg px-3 py-2 text-left hover:bg-base-200 aria-selected:bg-base-200"
          >
            <span class="badge badge-ghost badge-sm w-20 shrink-0 justify-center">{command.group}</span>
            <span class="min-w-0 flex-1">
              <span class="block truncate text-sm font-medium">{command.label}</span>
              <span class="block truncate text-xs text-base-content/50">{command.detail}</span>
            </span>
            <kbd :if={command.shortcut} class="kbd kbd-sm">{command.shortcut}</kbd>
          </button>
        </div>
        <footer class="flex gap-3 border-t border-base-300 px-3 py-2 text-xs text-base-content/50">
          <span><kbd class="kbd kbd-xs">↑</kbd><kbd class="kbd kbd-xs">↓</kbd> move</span>
          <span><kbd class="kbd kbd-xs">enter</kbd> open</span>
          <span class="ml-auto">Actions are labeled; approvals stay in their review card.</span>
        </footer>
      </section>
    </div>
    """
  end
end
