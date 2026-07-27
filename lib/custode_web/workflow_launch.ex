defmodule CustodeWeb.WorkflowLaunch do
  @moduledoc """
  The launch button (design/005 slice 3, #273): the first of the two entry
  points to a workflow run.

  Workflows are repo-scoped, so the button lives wherever a repository does --
  the repositories page (#193) and the repo panel on a repo-tied agent's page.
  The component and the `propose_workflow` handler both live here so those two
  surfaces cannot drift into meaning different things by the same click.

  What the click does is open a gate. design/005 is explicit that there is no
  second path to a run: the button proposes, `Custode.Workflow.Launch` prices
  it, and nothing is enqueued until the operator approves on /workflows. The
  `:why` says where the click came from, so a gate read an hour later still
  explains itself.

  The menu quotes the node floor from the definition, which is pure. The price
  needs a ledger read per repo, and that belongs on the gate card the operator
  is actually deciding from, not on every render of every tile.
  """

  use Phoenix.Component

  alias Custode.Workflow
  alias Custode.Workflow.Catalog
  alias Custode.Workflow.Launch

  @doc """
  Every standing gate as `%{repo => %{workflow => proposal_id}}`, so a pair
  that already has a gate offers that gate instead of minting a second one.

  One read for the whole page: the repositories page renders N tiles and a
  per-tile query would multiply by N for an answer that is the same list.

  The grouping lives in `Custode.Workflow.Launch` because the dryness advisor
  (slice 4) suppresses itself on the same answer -- a button and a cron that
  disagreed about "already proposed" would double-bill the operator's
  attention.
  """
  defdelegate standing(), to: Launch

  @doc "The standing gates for one repo, as `%{workflow => proposal_id}`."
  defdelegate standing_for(repo), to: Launch

  @doc """
  Handle a `propose_workflow` click. Both pages delegate here; `why` names the
  surface the click came from.
  """
  def propose(socket, %{"workflow" => workflow, "repo" => repo}, why) do
    case Launch.propose(workflow, repo, why: why) do
      {:ok, _proposal} ->
        Phoenix.LiveView.put_flash(
          socket,
          :info,
          "launch gate open for #{workflow} on #{repo} -- approve it on /workflows"
        )

      {:error, :unknown_workflow} ->
        Phoenix.LiveView.put_flash(socket, :error, "no workflow named #{workflow}")
    end
  end

  attr(:repo, :string, required: true)
  attr(:standing, :map, default: %{})
  attr(:class, :string, default: nil)

  @doc """
  The button: pick a workflow from the catalog for one repo.

  An empty catalog renders nothing rather than an empty menu -- there is no
  decision to offer.
  """
  def launch_button(assigns) do
    assigns = assign(assigns, :catalog, Catalog.all())

    ~H"""
    <div :if={@catalog != %{}} class={["dropdown dropdown-end", @class]}>
      <div tabindex="0" role="button" class="btn btn-ghost btn-xs gap-1">
        run a workflow
        <span class="text-base-content/40">&#9662;</span>
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu z-10 w-72 gap-1 rounded-box bg-base-200 p-2 shadow"
      >
        <li :for={{name, definition} <- Enum.sort_by(@catalog, &elem(&1, 0))}>
          <.link
            :if={@standing[name]}
            navigate="/workflows"
            class="flex-col items-start gap-0"
            title="a launch gate for this workflow is already waiting on you"
          >
            <span class="font-mono text-sm">{name}</span>
            <span class="text-xs text-warning">gate already standing &mdash; decide it</span>
          </.link>
          <button
            :if={!@standing[name]}
            class="flex-col items-start gap-0"
            phx-click="propose_workflow"
            phx-value-workflow={name}
            phx-value-repo={@repo}
          >
            <span class="font-mono text-sm">{name}</span>
            <span class="text-xs text-base-content/50">{nodes_line(definition)}</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp nodes_line(definition) do
    case Workflow.node_floor(definition) do
      {known, true} -> "#{known}+ nodes, then a fan-out"
      {known, false} -> "#{known} nodes"
    end
  end
end
