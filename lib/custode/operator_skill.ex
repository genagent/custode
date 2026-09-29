defmodule Custode.OperatorSkill do
  @moduledoc """
  Installs the provider-neutral Custode operator skill for interactive agents.

  The artifact contains workflow guidance only. MCP connection details and the
  operator token stay in each host's configuration and are never copied into
  the skill directory.
  """

  @name "custode-operator"
  @version "custode.operator-skill.v1"
  @targets [:claude, :codex]

  @type target :: :claude | :codex | :all
  @type install_status :: :installed | :current | :updated
  @type install_result :: %{
          target: :claude | :codex,
          path: String.t(),
          status: install_status(),
          version: String.t()
        }

  @doc "The skill folder name used by both hosts."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The workflow contract version declared by the packaged skill."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The packaged SKILL.md path."
  @spec source_path() :: String.t()
  def source_path do
    Application.app_dir(:custode, Path.join(["priv", "skills", @name, "SKILL.md"]))
  end

  @doc "The host-specific destination directory for the shared skill."
  @spec destination(:claude | :codex, keyword()) :: String.t()
  def destination(target, opts \\ [])

  def destination(:claude, opts) do
    root = config_root(opts, :claude_home, "CLAUDE_CONFIG_DIR", ".claude")
    Path.join([root, "skills", @name])
  end

  def destination(:codex, opts) do
    root = config_root(opts, :codex_home, "CODEX_HOME", ".codex")
    Path.join([root, "skills", @name])
  end

  @doc """
  Install the packaged skill for Claude Code, Codex, or both.

  An identical installed file is left alone. Different existing content is
  refused unless `force: true` is supplied. All requested destinations are
  checked before the first write, so a conflict cannot produce a partial
  multi-host install.
  """
  @spec install(target(), keyword()) :: {:ok, [install_result()]} | {:error, term()}
  def install(target, opts \\ []) do
    with {:ok, targets} <- targets(target),
         {:ok, content} <- File.read(source_path()),
         {:ok, plans} <- plans(targets, content, opts) do
      apply_plans(plans, content)
    end
  end

  defp targets(:all), do: {:ok, @targets}
  defp targets(target) when target in @targets, do: {:ok, [target]}
  defp targets(target), do: {:error, {:unknown_target, target}}

  defp plans(targets, content, opts) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, plans} ->
      path = Path.join(destination(target, opts), "SKILL.md")

      case install_status(path, content, opts[:force] == true) do
        {:ok, status} -> {:cont, {:ok, [%{path: path, status: status, target: target} | plans]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      error -> error
    end
  end

  defp install_status(path, content, force?) do
    with :ok <- reject_symlink(Path.dirname(path)),
         :ok <- reject_symlink(path) do
      case File.read(path) do
        {:ok, ^content} -> {:ok, :current}
        {:ok, _different} when force? -> {:ok, :updated}
        {:ok, _different} -> {:error, {:conflict, path}}
        {:error, :enoent} -> {:ok, :installed}
        {:error, reason} -> {:error, {:read_failed, path, reason}}
      end
    end
  end

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> {:error, {:symlink, path}}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp apply_plans(plans, content) do
    Enum.reduce_while(plans, {:ok, []}, fn plan, {:ok, results} ->
      case write_plan(plan, content) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp write_plan(%{status: :current} = plan, _content), do: {:ok, result(plan)}

  defp write_plan(plan, content) do
    temporary = plan.path <> ".tmp-#{System.unique_integer([:positive])}"

    case write_temporary(temporary, plan, content) do
      :ok ->
        published = publish(plan, temporary, content)
        File.rm(temporary)
        published

      {:error, reason} ->
        File.rm(temporary)
        {:error, {:write_failed, plan.path, reason}}
    end
  end

  defp write_temporary(temporary, plan, content) do
    case File.mkdir_p(Path.dirname(plan.path)) do
      :ok -> File.write(temporary, content, [:exclusive])
      {:error, _reason} = error -> error
    end
  end

  # A hard link is an atomic exclusive publication: a file created after the
  # preflight cannot be replaced. Force updates use rename's atomic replace.
  defp publish(%{status: :installed} = plan, temporary, content) do
    case File.ln(temporary, plan.path) do
      :ok ->
        {:ok, result(plan)}

      {:error, :eexist} ->
        concurrent_install(plan, content)

      {:error, reason} ->
        {:error, {:write_failed, plan.path, reason}}
    end
  end

  defp publish(plan, temporary, _content) do
    case File.rename(temporary, plan.path) do
      :ok -> {:ok, result(plan)}
      {:error, reason} -> {:error, {:write_failed, plan.path, reason}}
    end
  end

  defp concurrent_install(plan, content) do
    case File.read(plan.path) do
      {:ok, ^content} -> {:ok, result(%{plan | status: :current})}
      {:ok, _different} -> {:error, {:conflict, plan.path}}
      {:error, reason} -> {:error, {:write_failed, plan.path, reason}}
    end
  end

  defp result(plan) do
    %{
      target: plan.target,
      path: Path.dirname(plan.path),
      status: plan.status,
      version: @version
    }
  end

  defp config_root(opts, option, variable, fallback) do
    case Keyword.fetch(opts, option) do
      {:ok, root} ->
        Path.expand(root)

      :error ->
        env = Keyword.get(opts, :env, &System.get_env/1)

        case env.(variable) do
          root when is_binary(root) and root != "" -> Path.expand(root)
          _unset -> Path.join(user_home(opts), fallback)
        end
    end
  end

  defp user_home(opts) do
    case Keyword.fetch(opts, :user_home) do
      {:ok, home} -> Path.expand(home)
      :error -> System.user_home!()
    end
  end
end
