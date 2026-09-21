defmodule Custode.Gates.Risk do
  @moduledoc """
  The risk of a change, read off the paths it touches (#451).

  A gate's class says what KIND of action is asked for; it does not say what
  the action reaches. "Merge a lockfile bump" and "merge a migration" are
  both `merge`, and only one of them is something to hand to anyone but the
  operator. This is the second axis, and like the class it only records.

  Pure: paths in, a level and the paths that set it out. The highest match
  wins. `nil` anywhere upstream (no pull request, a diff that could not be
  read) stays `nil`: unknown is not low.
  """

  @type level :: String.t()
  @type t :: %{level: level(), matched: [String.t()]}

  # {level, what it is, pattern}. Ordered high to low; the first level with
  # any match is the answer, and every path matching THAT level is evidence.
  @rules [
    {"high", ~r{(^|/)migrations/}},
    {"high", ~r{^\.github/workflows/}},
    {"high", ~r{(^|/)(auth|secrets?|credentials?)(/|\.|_|$)}i},
    {"high", ~r{(^|/)\.env(\.|$)}},
    {"high",
     ~r{(^|/)(release-please-config\.json|\.release-please-manifest\.json|release\.ya?ml)$}},
    {"elevated",
     ~r{(^|/)(mix\.lock|Cargo\.lock|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|poetry\.lock|go\.sum)$}},
    {"elevated", ~r{(^|/)(mix\.exs|Cargo\.toml|package\.json|pyproject\.toml|go\.mod)$}},
    {"elevated", ~r{(^|/)Dockerfile(\.|$)}},
    {"elevated", ~r{(^|/)config/(runtime|prod)\.exs$}}
  ]

  @levels ~w(high elevated low)

  @doc "The levels, most severe first."
  @spec levels() :: [level()]
  def levels, do: @levels

  @doc """
  Assess a list of changed paths.

      iex> Custode.Gates.Risk.assess(["lib/a.ex", "priv/repo/migrations/1_x.exs", "mix.lock"])
      %{level: "high", matched: ["priv/repo/migrations/1_x.exs"]}
      iex> Custode.Gates.Risk.assess(["README.md", "mix.lock"])
      %{level: "elevated", matched: ["mix.lock"]}
      iex> Custode.Gates.Risk.assess(["README.md"])
      %{level: "low", matched: []}
  """
  @spec assess([String.t()]) :: t()
  def assess(paths) when is_list(paths) do
    Enum.find_value(["high", "elevated"], %{level: "low", matched: []}, &at_level(paths, &1))
  end

  defp at_level(paths, level) do
    patterns = for {^level, pattern} <- @rules, do: pattern

    case Enum.filter(paths, &matches_any?(&1, patterns)) do
      [] -> nil
      matched -> %{level: level, matched: Enum.uniq(matched)}
    end
  end

  defp matches_any?(path, patterns), do: Enum.any?(patterns, &Regex.match?(&1, path))

  @doc """
  The paths a diff touches, from `Custode.Repository.pr_diff/2` rows. A
  rename counts on both sides: moving a file OUT of `migrations/` is a change
  to migrations.
  """
  @spec paths([map()]) :: [String.t()]
  def paths(files) when is_list(files) do
    files
    |> Enum.flat_map(&[&1[:filename], &1[:previous_filename]])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end
end
