defmodule CustodeWeb.ReposLive do
  @moduledoc """
  The repositories page (#193): the repo-centric axis of the dashboard. One
  tile per distinct repository in the roster, each carrying the shared
  issues/PRs panel plus the agents that work it -- the fleet page answers
  "who is working", this page answers "how is each repo doing".

  Overviews come from the same `Custode.GitHub` cache the agent page reads,
  so N tiles cost no more than N agent-page visits; the
  `{:repo_overview, repo}` broadcast fills tiles in live as fetches land.

  It is also where the workflow button lives (#273): workflows are repo-scoped,
  so this is the page that has the repo to scope one to.
  """

  use Phoenix.LiveView

  alias CustodeWeb.AttentionSnapshot

  import CustodeWeb.Components

  alias CustodeWeb.WorkflowLaunch

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()
    {:ok, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def handle_info({:repo_overview, _repo}, socket), do: {:noreply, refresh(socket)}
  def handle_info(message, socket), do: {:noreply, AttentionSnapshot.refresh_for(socket, message)}

  @impl Phoenix.LiveView
  def handle_event("propose_workflow", params, socket) do
    {:noreply,
     socket
     |> WorkflowLaunch.propose(params, "launched by hand from the repositories page")
     |> refresh()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page attention_signals={@attention_signals} fleet_today={@fleet_today} active={:repos}>
      <.page_header title="Repos" summary={"#{length(@repos)} #{if length(@repos) == 1, do: "repository", else: "repositories"} in the roster."} />
      <p :if={@repos == []} class="text-sm text-base-content/40">
        no repositories in the roster yet -- add a repo-tied agent on the fleet page
      </p>
      <div class="space-y-8">
        <section :for={{repo, agents} <- @repos} class="min-w-0 rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="mb-2 flex flex-wrap items-baseline gap-2 text-lg font-semibold text-base-content/70">
            <a
              href={"https://github.com/#{repo}"}
              target="_blank"
              class="link link-hover font-mono [overflow-wrap:anywhere]"
            >
              {repo}
            </a>
            <.link
              :for={{agent, role} <- agents}
              navigate={"/console/#{agent}"}
              class="badge badge-ghost badge-sm gap-1 font-mono"
              title={Custode.Roles.summary(role)}
            >
              {agent}
              <span class="opacity-60">&middot; {role}</span>
            </.link>
            <span
              :if={overview(@overviews, repo) == :loading}
              class="loading loading-dots loading-xs"
            >
            </span>
            <WorkflowLaunch.launch_button
              repo={repo}
              standing={Map.get(@standing, repo, %{})}
              class="ml-auto"
            />
          </h2>
          <.repo_overview_panel overview={overview(@overviews, repo)} />
        </section>
      </div>
    </.page>
    """
  end

  defp overview(overviews, repo), do: Map.get(overviews, repo)

  # active-cadence agents (the loud worker) sort before quiet ones (the
  # steward), then by id -- the registry supplies the cadence
  defp agent_order({id, role}) do
    {if(Custode.Roles.cadence(role) == :active, do: 0, else: 1), id}
  end

  # Dedupe repos across the roster (several agents can work one repo). Each
  # agent carries its role so the tile shows the repo's staffing (#255): the
  # loud worker before the quiet steward, then by id.
  defp refresh(socket) do
    socket = AttentionSnapshot.refresh(socket)

    repos =
      Custode.Routine.all()
      |> Enum.filter(& &1.repo)
      |> Enum.group_by(& &1.repo, &{&1.id, &1.role})
      |> Enum.map(fn {repo, agents} -> {repo, Enum.sort_by(agents, &agent_order/1)} end)
      |> Enum.sort_by(fn {repo, _agents} -> repo end)

    overviews =
      Map.new(repos, fn {repo, _agents} ->
        case Custode.GitHub.overview(repo) do
          {:ok, overview} -> {repo, overview}
          :loading -> {repo, :loading}
          # the tile's panel draws the reason where the overview would be (#485)
          {:error, reason} -> {repo, {:error, reason}}
        end
      end)

    assign(socket,
      fleet_today: Custode.SpendLedger.fleet_today(),
      repos: repos,
      overviews: overviews,
      standing: WorkflowLaunch.standing()
    )
  end
end
