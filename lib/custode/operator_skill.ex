defmodule Custode.OperatorSkill do
  @moduledoc """
  Installs and inspects the provider-neutral Custode operator skill.

  The installed package contains workflow guidance only. MCP connection details
  and the operator token stay in each host's configuration and are never copied
  into the skill directory.
  """

  @name "custode-operator"
  @version "custode.operator-skill.v2"
  @targets [:claude, :codex]
  @manifest ".custode-package.json"
  @manifest_schema 1
  @legacy_v1_skill_sha256 "02ae28528af7e59d6cc6d962c741bdb526ea772f1e9318bafdd1a43e182ec839"
  # Add an exact {version, digest} pair here when a manifest-backed package is
  # superseded. Unknown manifests are modified, even when internally
  # consistent, because their contents were never published by Custode.
  @known_stale_packages MapSet.new()

  @type target :: :claude | :codex | :all
  @type install_status :: :installed | :current | :updated
  @type package_state :: :missing | :current | :stale | :modified
  @type install_result :: %{
          target: :claude | :codex,
          path: String.t(),
          status: install_status(),
          version: String.t(),
          digest: String.t()
        }
  @type status_result :: %{
          target: :claude | :codex,
          path: String.t(),
          state: package_state(),
          expected_version: String.t(),
          expected_digest: String.t(),
          installed_version: String.t() | nil,
          installed_digest: String.t() | nil
        }

  @doc "The skill folder name used by both hosts."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The workflow contract version declared by the packaged skill."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The packaged skill directory."
  @spec source_dir() :: String.t()
  def source_dir do
    Application.app_dir(:custode, Path.join(["priv", "skills", @name]))
  end

  @doc "The packaged SKILL.md path."
  @spec source_path() :: String.t()
  def source_path, do: Path.join(source_dir(), "SKILL.md")

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

  @doc false
  def install_lock_paths(target, opts \\ []) when target in @targets do
    root = install_lock_root(opts)

    target
    |> destination(opts)
    |> destination_identities()
    |> Enum.map(&install_lock_path(&1, root))
    |> Enum.sort()
  end

  @doc "Inspect one host's installed operator skill without changing it."
  @spec status(:claude | :codex, keyword()) :: {:ok, status_result()} | {:error, term()}
  def status(target, opts \\ []) when target in @targets do
    with {:ok, package} <- package(target),
         path = destination(target, opts),
         :ok <- reject_symlinks(path, Map.keys(package.files) ++ [@manifest]),
         {:ok, installed} <- installed_state(path, package) do
      {:ok,
       Map.merge(installed, %{
         target: target,
         path: path,
         expected_version: @version,
         expected_digest: package.digest
       })}
    end
  end

  @doc """
  Install the packaged skill for Claude Code, Codex, or both.

  Current installs are left alone and missing packages are installed. Older,
  locally modified, or malformed packages are refused unless `force: true` is
  supplied. Every requested destination is checked before the first write.
  """
  @spec install(target(), keyword()) :: {:ok, [install_result()]} | {:error, term()}
  def install(target, opts \\ []) do
    with {:ok, targets} <- targets(target),
         {:ok, plans} <- plans(targets, opts) do
      apply_plans(plans, opts[:force] == true, install_lock_root(opts))
    end
  end

  defp targets(:all), do: {:ok, @targets}
  defp targets(target) when target in @targets, do: {:ok, [target]}
  defp targets(target), do: {:error, {:unknown_target, target}}

  defp package(target) do
    with {:ok, files} <- package_files(source_dir()) do
      files = host_files(files, target)
      hashes = Map.new(files, fn {path, content} -> {path, sha256(content)} end)

      {:ok, %{digest: package_digest(hashes), files: files, hashes: hashes}}
    end
  end

  defp host_files(files, :codex), do: files

  defp host_files(files, :claude) do
    Map.update!(files, "SKILL.md", fn content ->
      String.replace(
        content,
        "description:",
        "disable-model-invocation: true\ndescription:",
        global: false
      )
    end)
  end

  defp package_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.reduce_while({:ok, %{}}, &collect_package_file(&1, &2, root))
    |> validate_package_files()
  end

  defp collect_package_file(path, {:ok, files}, root) do
    relative = Path.relative_to(path, root)

    cond do
      relative == @manifest ->
        {:cont, {:ok, files}}

      safe_relative_path?(relative) ->
        read_package_file(path, relative, files)

      true ->
        {:halt, {:error, {:invalid_package_path, relative}}}
    end
  end

  defp read_package_file(path, relative, files) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> read_regular_package_file(path, relative, files)
      {:ok, _other} -> {:halt, {:error, {:invalid_package_file, path}}}
      {:error, reason} -> {:halt, {:error, {:read_failed, path, reason}}}
    end
  end

  defp read_regular_package_file(path, relative, files) do
    case File.read(path) do
      {:ok, content} -> {:cont, {:ok, Map.put(files, relative, content)}}
      {:error, reason} -> {:halt, {:error, {:read_failed, path, reason}}}
    end
  end

  defp validate_package_files({:ok, files})
       when map_size(files) > 0 and is_map_key(files, "SKILL.md"),
       do: {:ok, files}

  defp validate_package_files({:ok, _files}), do: {:error, :missing_skill_entrypoint}
  defp validate_package_files(error), do: error

  defp plans(targets, opts) do
    destinations = Map.new(targets, &{&1, destination(&1, opts)})

    with :ok <- unique_destinations(destinations) do
      build_plans(targets, destinations, opts[:force] == true)
    end
  end

  defp build_plans(targets, destinations, force?) do
    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, plans} ->
      case build_plan(target, Map.fetch!(destinations, target), force?) do
        {:ok, plan} -> {:cont, {:ok, [plan | plans]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_plans()
  end

  defp build_plan(target, path, force?) do
    with {:ok, package} <- package(target),
         :ok <- reject_symlinks(path, Map.keys(package.files) ++ [@manifest]),
         {:ok, installed} <- installed_state(path, package),
         {:ok, action} <- install_action(installed.state, path, force?) do
      {:ok, %{action: action, package: package, path: path, target: target}}
    end
  end

  defp reverse_plans({:ok, plans}), do: {:ok, Enum.reverse(plans)}
  defp reverse_plans(error), do: error

  defp unique_destinations(destinations) do
    destinations
    |> Map.values()
    |> Enum.map(&{&1, destination_identities(&1)})
    |> duplicate_destination()
    |> case do
      nil -> :ok
      path -> {:error, {:duplicate_destination, Path.expand(path)}}
    end
  end

  defp duplicate_destination([]), do: nil

  defp duplicate_destination([{path, identities} | destinations]) do
    if Enum.any?(destinations, fn {_other_path, other_identities} ->
         not MapSet.disjoint?(identities, other_identities)
       end) do
      path
    else
      duplicate_destination(destinations)
    end
  end

  defp install_action(:current, _path, _force?), do: {:ok, :current}
  defp install_action(:missing, _path, _force?), do: {:ok, :installed}
  defp install_action(:stale, _path, true), do: {:ok, :updated}
  defp install_action(:stale, path, false), do: {:error, {:stale, path}}
  defp install_action(:modified, _path, true), do: {:ok, :updated}
  defp install_action(:modified, path, false), do: {:error, {:conflict, path}}

  defp apply_plans(plans, force?, lock_root) do
    identities =
      plans
      |> Enum.flat_map(fn plan -> MapSet.to_list(destination_identities(plan.path)) end)
      |> Enum.uniq()
      |> Enum.sort()

    with_install_locks(identities, fn ->
      apply_with_file_locks(identities, plans, force?, lock_root)
    end)
  end

  defp apply_with_file_locks(identities, plans, force?, lock_root) do
    case prepare_install_lock_root(lock_root) do
      :ok ->
        with_install_file_locks(identities, lock_root, fn ->
          recheck_and_write(plans, force?)
        end)

      {:error, reason} ->
        {:error, {:lock_failed, lock_root, reason}}
    end
  end

  defp recheck_and_write(plans, force?) do
    with {:ok, checked} <- recheck_plans(plans, force?) do
      write_plans(checked, force?)
    end
  end

  defp with_install_locks([], fun), do: fun.()

  defp with_install_locks([path | paths], fun) do
    :global.trans({{__MODULE__, path}, self()}, fn ->
      with_install_locks(paths, fun)
    end)
  end

  # :global serializes callers in this VM. Exclusive files extend the same
  # boundary to independent Mix processes so forced package replacement cannot
  # interleave. A crashed owner leaves a visible lock and fails closed.
  defp with_install_file_locks([], _root, fun), do: fun.()

  defp with_install_file_locks([identity | identities], root, fun) do
    path = install_lock_path(identity, root)
    token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    case File.write(path, token, [:exclusive]) do
      :ok ->
        try do
          with_install_file_locks(identities, root, fun)
        after
          release_install_file_lock(path, token)
        end

      {:error, :eexist} ->
        {:error, {:install_busy, path}}

      {:error, reason} ->
        {:error, {:lock_failed, path, reason}}
    end
  end

  defp prepare_install_lock_root(root) do
    with :ok <- File.mkdir_p(Path.dirname(root)),
         :ok <- mkdir_lock_root(root),
         {:ok, stat} <- File.lstat(root),
         :ok <- validate_lock_root(stat) do
      File.chmod(root, 0o700)
    end
  end

  defp mkdir_lock_root(root) do
    case File.mkdir(root) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_lock_root(%File.Stat{type: :directory, uid: uid}) do
    case {:os.type(), File.stat(System.user_home!())} do
      {{:unix, _name}, {:ok, %{uid: ^uid}}} -> :ok
      {{:unix, _name}, {:ok, _home_stat}} -> {:error, :wrong_owner}
      {{:unix, _name}, {:error, reason}} -> {:error, {:owner_check_failed, reason}}
      _other -> :ok
    end
  end

  defp validate_lock_root(%File.Stat{type: type}), do: {:error, {:unsafe_type, type}}

  defp install_lock_path(identity, root) do
    digest = identity |> :erlang.term_to_binary() |> sha256()
    Path.join(root, "#{digest}.lock")
  end

  defp release_install_file_lock(path, token) do
    case File.read(path) do
      {:ok, ^token} -> File.rm(path)
      _missing_or_replaced -> :ok
    end
  end

  # Recheck all targets while holding this VM's destination locks so a
  # concurrent local installer cannot introduce a second-target conflict after
  # the first target has already been written.
  defp recheck_plans(plans, force?) do
    Enum.reduce_while(plans, {:ok, []}, fn plan, {:ok, checked} ->
      package = plan.package

      with :ok <- reject_symlinks(plan.path, Map.keys(package.files) ++ [@manifest]),
           {:ok, installed} <- installed_state(plan.path, package),
           {:ok, action} <- install_action(installed.state, plan.path, force?) do
        {:cont, {:ok, [%{plan | action: action} | checked]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, checked} -> {:ok, Enum.reverse(checked)}
      error -> error
    end
  end

  defp write_plans(plans, force?) do
    Enum.reduce_while(plans, {:ok, []}, fn plan, {:ok, results} ->
      with {:ok, installed} <- installed_state(plan.path, plan.package),
           {:ok, action} <- install_action(installed.state, plan.path, force?),
           :ok <- write_package(plan.path, plan.package, installed, action) do
        {:cont, {:ok, [result(%{plan | action: action}, plan.package) | results]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp write_package(_path, _package, _installed, :current), do: :ok

  defp write_package(path, package, installed, action) do
    force_replace? = installed.state == :modified and action == :updated

    replaceable =
      if force_replace?,
        do: Map.keys(package.files),
        else: Map.get(installed, :owned_files, [])

    manifest_path = Path.join(path, @manifest)

    replace_manifest? =
      File.exists?(manifest_path) and
        (force_replace? or not is_nil(installed.installed_digest))

    with :ok <- File.mkdir_p(path),
         :ok <- remove_obsolete_owned_files(path, installed, Map.keys(package.files)),
         :ok <- write_files(path, package.files, MapSet.new(replaceable)) do
      write_atomic(manifest_path, manifest(package), replace_manifest?)
    end
  end

  defp write_files(path, files, replaceable) do
    files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {relative, content}, :ok ->
      destination = Path.join(path, relative)

      with :ok <- File.mkdir_p(Path.dirname(destination)),
           :ok <- write_atomic(destination, content, MapSet.member?(replaceable, relative)) do
        {:cont, :ok}
      else
        {:error, {:conflict, _path}} = error -> {:halt, error}
        {:error, reason} -> {:halt, {:error, {:write_failed, destination, reason}}}
      end
    end)
  end

  defp write_atomic(path, content, replace?) do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    temporary = path <> ".tmp-" <> suffix

    case File.write(temporary, content, [:exclusive]) do
      :ok ->
        try do
          publish_temporary(temporary, path, content, replace?)
        after
          File.rm(temporary)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_temporary(temporary, path, _content, true), do: File.rename(temporary, path)

  defp publish_temporary(temporary, path, content, false) do
    case File.ln(temporary, path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.read(path) do
          {:ok, ^content} -> :ok
          _different_or_unreadable -> {:error, {:conflict, path}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_obsolete_owned_files(path, installed, new_files) do
    installed
    |> Map.get(:owned_files, [])
    |> Enum.reject(&(&1 in new_files))
    |> Enum.reduce_while(:ok, fn relative, :ok ->
      file = Path.join(path, relative)

      case File.rm(file) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:write_failed, file, reason}}}
      end
    end)
  end

  defp installed_state(path, package) do
    skill = Path.join(path, "SKILL.md")
    manifest_path = Path.join(path, @manifest)

    case File.read(skill) do
      {:error, :enoent} ->
        if package_traces?(path, package) do
          {:ok, base_installed(:modified)}
        else
          {:ok, base_installed(:missing)}
        end

      {:error, reason} ->
        {:error, {:read_failed, skill, reason}}

      {:ok, skill_content} ->
        case File.read(manifest_path) do
          {:ok, encoded} -> classify_manifest(path, encoded, package)
          {:error, :enoent} -> classify_legacy(path, skill_content, package)
          {:error, reason} -> {:error, {:read_failed, manifest_path, reason}}
        end
    end
  end

  defp classify_legacy(path, skill_content, package) do
    colliding_new_file? =
      package.files
      |> Map.delete("SKILL.md")
      |> Map.keys()
      |> Enum.any?(&File.exists?(Path.join(path, &1)))

    state =
      if sha256(skill_content) == @legacy_v1_skill_sha256 and not colliding_new_file?,
        do: :stale,
        else: :modified

    installed =
      base_installed(state)
      |> Map.put(:installed_version, if(state == :stale, do: "custode.operator-skill.v1"))

    {:ok, if(state == :stale, do: %{installed | owned_files: ["SKILL.md"]}, else: installed)}
  end

  defp classify_manifest(path, encoded, package) do
    with {:ok, decoded} <- Jason.decode(encoded),
         {:ok, manifest} <- validate_manifest(decoded) do
      classify_valid_manifest(path, manifest, package)
    else
      _invalid -> {:ok, base_installed(:modified)}
    end
  end

  defp classify_valid_manifest(path, manifest, package) do
    with :ok <- reject_symlinks(path, Map.keys(manifest.files)) do
      files_match? = verify_installed_files(path, manifest.files) == :ok
      digest_matches_files? = manifest.digest == package_digest(manifest.files)
      identity = manifest_identity(manifest, package)

      state =
        manifest_state(
          identity,
          files_match?,
          digest_matches_files?,
          manifest.files == package.hashes
        )

      {:ok,
       %{
         state: state,
         installed_version: manifest.version,
         installed_digest: manifest.digest,
         owned_files: if(identity in [:current, :stale], do: Map.keys(manifest.files), else: [])
       }}
    end
  end

  defp manifest_identity(%{version: @version, digest: digest}, %{digest: digest}), do: :current

  defp manifest_identity(manifest, _package) do
    if MapSet.member?(@known_stale_packages, {manifest.version, manifest.digest}),
      do: :stale,
      else: :unknown
  end

  defp manifest_state(:unknown, _files?, _digest?, _current_files?), do: :modified
  defp manifest_state(_identity, false, _digest?, _current_files?), do: :modified
  defp manifest_state(_identity, _files?, false, _current_files?), do: :modified
  defp manifest_state(:current, true, true, true), do: :current
  defp manifest_state(:stale, true, true, _current_files?), do: :stale
  defp manifest_state(_identity, _files?, _digest?, _current_files?), do: :modified

  defp validate_manifest(%{
         "schema" => @manifest_schema,
         "name" => @name,
         "version" => version,
         "digest" => digest,
         "files" => files
       })
       when is_binary(version) and is_binary(digest) and is_map(files) do
    if is_map_key(files, "SKILL.md") and
         Enum.all?(files, fn {path, hash} ->
           is_binary(path) and safe_relative_path?(path) and path != @manifest and
             valid_sha256?(hash)
         end) do
      {:ok, %{version: version, digest: digest, files: files}}
    else
      {:error, :invalid_manifest}
    end
  end

  defp validate_manifest(_other), do: {:error, :invalid_manifest}

  defp verify_installed_files(path, files) do
    Enum.reduce_while(files, :ok, fn {relative, expected}, :ok ->
      case verify_installed_file(path, relative, expected) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_installed_file(path, relative, expected) do
    with {:ok, content} <- File.read(Path.join(path, relative)),
         true <- sha256(content) == expected do
      :ok
    else
      _missing_or_changed -> {:error, :modified}
    end
  end

  defp package_traces?(path, package) do
    File.exists?(Path.join(path, @manifest)) or
      Enum.any?(Map.keys(package.files), &File.exists?(Path.join(path, &1)))
  end

  defp manifest(package) do
    Jason.encode!(%{
      "schema" => @manifest_schema,
      "name" => @name,
      "version" => @version,
      "digest" => package.digest,
      "files" => package.hashes
    }) <> "\n"
  end

  defp base_installed(state) do
    %{state: state, installed_version: nil, installed_digest: nil, owned_files: []}
  end

  defp reject_symlinks(root, relative_paths) do
    relative_paths
    |> path_expectations(root)
    |> Enum.reduce_while(:ok, fn {path, expected}, :ok ->
      case validate_path_type(path, expected) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp path_expectations(relative_paths, root) do
    Enum.reduce(relative_paths, %{root => :directory}, fn relative, expected ->
      add_path_expectations(expected, path_prefixes(root, relative))
    end)
  end

  defp add_path_expectations(expected, prefixes) do
    last = List.last(prefixes)

    Enum.reduce(prefixes, expected, fn path, acc ->
      Map.put(acc, path, if(path == last, do: :file, else: :directory))
    end)
  end

  defp validate_path_type(path, expected) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> {:error, {:symlink, path}}
      {:ok, %{type: :directory}} when expected == :directory -> :ok
      {:ok, %{type: :regular}} when expected == :file -> :ok
      {:ok, %{type: actual}} -> {:error, {:unexpected_file_type, path, actual}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp path_prefixes(root, relative) do
    relative
    |> Path.split()
    |> Enum.scan(root, &Path.join(&2, &1))
  end

  defp destination_identities(path) do
    expanded = Path.expand(path)
    parts = Path.split(expanded)
    prefixes = Enum.scan(parts, fn part, prefix -> Path.join(prefix, part) end)

    inode_identities =
      prefixes
      |> Enum.with_index()
      |> Enum.flat_map(fn {prefix, index} ->
        inode_identity(prefix, Enum.drop(parts, index + 1))
      end)

    MapSet.new([{:path, normalize_identity(expanded)} | inode_identities])
  end

  defp inode_identity(prefix, suffix) do
    case File.stat(prefix) do
      {:ok, stat} ->
        normalized_suffix = Enum.map(suffix, &normalize_identity/1)

        [
          {:inode, stat.major_device, stat.minor_device, stat.inode, normalized_suffix}
        ]

      {:error, _reason} ->
        []
    end
  end

  defp normalize_identity(value) do
    value
    |> :string.casefold()
    |> IO.iodata_to_binary()
    |> String.normalize(:nfc)
  end

  defp safe_relative_path?(path) do
    is_binary(path) and path != "" and Path.type(path) != :absolute and
      Enum.all?(Path.split(path), &(&1 not in ["", ".", ".."]))
  end

  defp sha256(data) do
    data
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp package_digest(hashes) do
    hashes
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {path, hash} -> [path, <<0>>, hash, <<10>>] end)
    |> sha256()
  end

  defp valid_sha256?(hash) when is_binary(hash) do
    byte_size(hash) == 64 and String.match?(hash, ~r/\A[0-9a-f]{64}\z/)
  end

  defp valid_sha256?(_hash), do: false

  defp result(plan, package) do
    %{
      target: plan.target,
      path: plan.path,
      status: plan.action,
      version: @version,
      digest: package.digest
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

  defp install_lock_root(opts) do
    Keyword.get_lazy(opts, :install_lock_root, &default_install_lock_root/0)
  end

  defp default_install_lock_root do
    case {:os.type(), File.stat(System.user_home!())} do
      {{:unix, _name}, {:ok, stat}} ->
        Path.join("/tmp", "custode-operator-install-locks-#{stat.uid}")

      _other ->
        Path.join([System.user_home!(), ".custode", "install-locks"])
    end
  end
end
