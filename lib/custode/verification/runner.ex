defmodule Custode.Verification.Runner do
  @moduledoc """
  Shell-free argv runner with bounded output, timeout, and process-tree cleanup.

  A fixed private shell helper performs only stdout/stderr redirection before
  `exec`. Command text is never interpolated or evaluated by that helper.
  Completion includes terminating every descendant identity observed while the
  command was running. The optional `stdin: :null` setting supplies EOF through
  the fixed helper; the default retains inherited port input. A cleanup that cannot verify process death is reported
  as an infrastructure error.
  """

  alias Custode.Verification.CommandSpec

  @runner_version "verification-runner-v3"
  @poll_ms 10
  @tree_poll_ms 100
  @kill_grace_ms 50
  @kill_verify_ms 200
  @cancellation_exit_codes [130, 137, 143]

  @spec run(CommandSpec.t() | map(), String.t(), keyword()) :: {:ok, map()}
  def run(spec, workspace_path, options \\ [])

  def run(%CommandSpec{} = spec, workspace_path, options) do
    started = System.monotonic_time(:millisecond)

    case preflight(spec, workspace_path) do
      {:ok, runtime} ->
        execute(spec, runtime, started, options)

      {:error, {:policy, reason}} ->
        {:ok, result(spec, "policy_refusal", reason, nil, started, empty_output(spec))}

      {:error, {:infrastructure, reason}} ->
        {:ok, result(spec, "infrastructure_error", reason, nil, started, empty_output(spec))}
    end
  end

  def run(spec, workspace_path, options) when is_map(spec) or is_list(spec) do
    case CommandSpec.new(spec) do
      {:ok, parsed} ->
        run(parsed, workspace_path, options)

      {:error, reason} ->
        fallback = fallback_spec(spec)
        started = System.monotonic_time(:millisecond)
        {:ok, result(fallback, "policy_refusal", reason, nil, started, empty_output(fallback))}
    end
  end

  @doc "Drop full captured output while retaining bounded query metadata."
  def metadata(result), do: Map.delete(result, "output")

  def runner_version, do: @runner_version

  defp preflight(spec, workspace_path) do
    with {:ok, cwd} <- contained_cwd(workspace_path, spec.working_directory),
         {:ok, executable} <- executable(hd(spec.argv)),
         {:ok, env_executable} <- executable("env"),
         {:ok, helper} <- helper() do
      environment =
        System.get_env()
        |> Map.take(spec.environment_allowlist)
        |> Map.merge(stringify_keys(spec.environment))

      {:ok,
       %{
         cwd: cwd,
         executable: executable,
         env_executable: env_executable,
         helper: helper,
         environment: environment
       }}
    end
  end

  defp contained_cwd(workspace_path, relative) when is_binary(workspace_path) do
    root = Path.expand(workspace_path)
    cwd = Path.expand(relative, root)

    with true <- File.dir?(root),
         true <- File.dir?(cwd),
         {:ok, physical_root} <- physical_path(root),
         {:ok, physical_cwd} <- physical_path(cwd),
         true <- contained?(physical_root, physical_cwd) do
      {:ok, physical_cwd}
    else
      false -> {:error, {:policy, :working_directory_refused}}
      {:error, _reason} -> {:error, {:policy, :working_directory_refused}}
    end
  end

  defp contained_cwd(_workspace_path, _relative),
    do: {:error, {:policy, :working_directory_refused}}

  defp contained?(root, path) do
    relative = Path.relative_to(path, root)

    Path.type(relative) == :relative and relative != ".." and
      not String.starts_with?(relative, "../")
  end

  defp physical_path(path) do
    case System.cmd("pwd", ["-P"], cd: path, stderr_to_stdout: true) do
      {physical, 0} -> {:ok, String.trim(physical)}
      {_output, _status} -> {:error, :physical_path_unavailable}
    end
  end

  defp executable(command) do
    case System.find_executable(command) do
      nil -> {:error, {:infrastructure, {:executable_not_found, command}}}
      path -> {:ok, path}
    end
  end

  defp helper do
    path = Application.app_dir(:custode, "priv/verification/exec_argv.sh")
    if File.regular?(path), do: {:ok, path}, else: {:error, {:infrastructure, :runner_missing}}
  end

  defp execute(spec, runtime, started, options) do
    directory = Path.join(System.tmp_dir!(), "custode-verification-#{Ecto.UUID.generate()}")
    stdout = Path.join(directory, "stdout")
    stderr = Path.join(directory, "stderr")

    with :ok <- File.mkdir(directory),
         {:ok, port} <- open_port(spec, runtime, stdout, stderr, options) do
      os_pid = port_pid(port)
      deadline = started + spec.timeout_ms

      outcome =
        await(
          port,
          os_pid,
          stdout,
          stderr,
          spec,
          deadline,
          options,
          %{known: %{}, next_scan: started}
        )

      output = capture_output(stdout, stderr, spec)
      File.rm_rf(directory)
      {:ok, result} = finish_execution(spec, outcome, started, output)
      {:ok, Map.put(result, "stdin_mode", stdin_mode(options))}
    else
      {:error, reason} ->
        File.rm_rf(directory)

        {:ok,
         result(
           spec,
           "infrastructure_error",
           reason,
           nil,
           started,
           empty_output(spec)
         )}
    end
  end

  defp open_port(spec, runtime, stdout, stderr, options) do
    [_command | arguments] = spec.argv

    environment =
      runtime.environment |> Enum.sort() |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)

    args =
      ["-i" | environment] ++
        [
          "/bin/sh",
          runtime.helper,
          stdout,
          stderr,
          stdin_mode(options),
          runtime.executable
          | arguments
        ]

    {:ok,
     Port.open(
       {:spawn_executable, runtime.env_executable},
       [:binary, :exit_status, :eof, :hide, args: args, cd: runtime.cwd]
     )}
  rescue
    error -> {:error, {:port_open_failed, Exception.message(error), hd(spec.argv)}}
  end

  defp stdin_mode(options),
    do: if(Keyword.get(options, :stdin) == :null, do: "null", else: "inherit")

  defp port_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp await(port, os_pid, stdout, stderr, spec, deadline, options, tree) do
    receive do
      {^port, {:exit_status, status}} ->
        finish_process_tree(port, Map.delete(tree.known, os_pid), {:exit, status})

      {^port, :eof} ->
        await(port, os_pid, stdout, stderr, spec, deadline, options, tree)

      {^port, {:data, _unexpected}} ->
        await(port, os_pid, stdout, stderr, spec, deadline, options, tree)
    after
      @poll_ms ->
        tree = maybe_observe_process_tree(os_pid, tree)

        cond do
          cancelled?(options) ->
            finish_process_tree(
              port,
              observe_process_tree(os_pid, tree.known),
              {:forced, "cancellation", :cancelled}
            )

          System.monotonic_time(:millisecond) >= deadline ->
            finish_process_tree(
              port,
              observe_process_tree(os_pid, tree.known),
              {:forced, "timeout", :timeout}
            )

          output_limit_exceeded?(stdout, stderr, spec.output_limit_bytes) ->
            finish_process_tree(
              port,
              observe_process_tree(os_pid, tree.known),
              {:forced, "policy_refusal", :output_limit_exceeded}
            )

          true ->
            await(port, os_pid, stdout, stderr, spec, deadline, options, tree)
        end
    end
  end

  defp cancelled?(options) do
    options
    |> Keyword.get(:cancelled?, fn -> false end)
    |> then(fn callback ->
      try do
        callback.()
      rescue
        _error -> false
      end
    end)
  end

  defp output_limit_exceeded?(stdout, stderr, limit) do
    file_size(stdout) > limit or file_size(stderr) > limit
  end

  defp observe_process_tree(nil, known), do: known

  defp observe_process_tree(root_pid, known) do
    case process_snapshot() do
      {:ok, snapshot} ->
        observed =
          [root_pid | descendants(root_pid, snapshot)]
          |> then(&Map.take(snapshot, &1))
          |> Map.new(fn {pid, process} -> {pid, process.started} end)

        Map.merge(known, observed)

      {:error, _reason} ->
        known
    end
  end

  defp maybe_observe_process_tree(root_pid, tree) do
    now = System.monotonic_time(:millisecond)

    if now >= tree.next_scan do
      %{known: observe_process_tree(root_pid, tree.known), next_scan: now + @tree_poll_ms}
    else
      tree
    end
  end

  defp finish_process_tree(port, known, outcome) when map_size(known) == 0 do
    close_port(port)
    outcome
  end

  defp finish_process_tree(port, known, outcome) do
    owned = alive_owned(known)
    pids = Map.keys(owned)
    signal(pids, "-STOP")

    frozen =
      Enum.reduce(1..3, owned, fn _iteration, observed ->
        discovered = discover_owned_descendants(observed)

        signal(Map.keys(discovered), "-STOP")
        discovered
      end)

    pids = Map.keys(frozen)
    signal(Enum.reverse(pids), "-TERM")
    signal(pids, "-CONT")

    survivors = await_death(frozen, @kill_grace_ms)
    signal(survivors |> Map.keys() |> Enum.reverse(), "-KILL")
    survivors = await_death(survivors, @kill_verify_ms)
    close_port(port)

    case Map.keys(survivors) do
      [] -> outcome
      pids -> {:cleanup_failed, outcome, Enum.sort(pids)}
    end
  end

  defp discover_owned_descendants(owned) do
    case process_snapshot() do
      {:ok, snapshot} ->
        current = alive_owned(owned, snapshot)

        discovered =
          current
          |> Map.keys()
          |> Enum.flat_map(&descendants(&1, snapshot))
          |> then(&Map.take(snapshot, &1))
          |> Map.new(fn {pid, process} -> {pid, process.started} end)

        Map.merge(current, discovered)

      {:error, _reason} ->
        owned
    end
  end

  defp await_death(pids, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_death_until(pids, deadline)
  end

  defp await_death_until(pids, deadline) do
    survivors = alive_owned(pids)

    cond do
      map_size(survivors) == 0 ->
        %{}

      System.monotonic_time(:millisecond) >= deadline ->
        survivors

      true ->
        Process.sleep(@poll_ms)
        await_death_until(survivors, deadline)
    end
  end

  defp alive_owned(owned) do
    case process_snapshot() do
      {:ok, snapshot} -> alive_owned(owned, snapshot)
      {:error, _reason} -> owned
    end
  end

  defp alive_owned(owned, snapshot) do
    Map.filter(owned, fn {pid, started} ->
      case Map.get(snapshot, pid) do
        %{started: ^started, state: state} -> not String.starts_with?(state, "Z")
        _missing_or_reused -> false
      end
    end)
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp process_snapshot do
    case System.cmd("ps", ["-axo", "pid=,ppid=,stat=,lstart="], stderr_to_stdout: true) do
      {output, 0} ->
        snapshot =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, &put_process/2)

        {:ok, snapshot}

      {output, status} ->
        {:error, {:process_snapshot_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:process_snapshot_failed, Exception.message(error)}}
  end

  defp put_process(line, snapshot) do
    case String.split(line, ~r/\s+/, trim: true, parts: 4) do
      [pid, parent, state, started] ->
        with {pid, ""} <- Integer.parse(pid),
             {parent, ""} <- Integer.parse(parent) do
          Map.put(snapshot, pid, %{parent: parent, state: state, started: started})
        else
          _invalid -> snapshot
        end

      _invalid ->
        snapshot
    end
  end

  defp descendants(root_pid, snapshot) do
    children = Enum.group_by(snapshot, fn {_pid, process} -> process.parent end, &elem(&1, 0))
    collect_descendants([root_pid], children, [])
  end

  defp collect_descendants([], _children, collected), do: collected

  defp collect_descendants([parent | rest], children, collected) do
    direct = Map.get(children, parent, [])
    collect_descendants(rest ++ direct, children, direct ++ collected)
  end

  defp signal([], _signal), do: :ok

  defp signal(pids, signal_name) do
    case System.find_executable("kill") do
      nil ->
        :ok

      executable ->
        Enum.each(pids, fn pid ->
          System.cmd(executable, [signal_name, Integer.to_string(pid)], stderr_to_stdout: true)
        end)
    end
  end

  defp finish_execution(spec, {:exit, exit_code}, started, output) do
    cond do
      output["stdout"]["truncated"] or output["stderr"]["truncated"] ->
        {:ok, result(spec, "policy_refusal", :output_limit_exceeded, exit_code, started, output)}

      exit_code in @cancellation_exit_codes ->
        {:ok, result(spec, "cancellation", :command_cancelled, exit_code, started, output)}

      exit_code in spec.expected_exit_codes ->
        {:ok, result(spec, "pass", nil, exit_code, started, output)}

      true ->
        {:ok, result(spec, "test_failure", :unexpected_exit, exit_code, started, output)}
    end
  end

  defp finish_execution(spec, {:forced, status, reason}, started, output),
    do: {:ok, result(spec, status, reason, nil, started, output)}

  defp finish_execution(spec, {:cleanup_failed, outcome, pids}, started, output) do
    exit_code = if match?({:exit, _status}, outcome), do: elem(outcome, 1)

    {:ok,
     result(
       spec,
       "infrastructure_error",
       {:process_tree_cleanup_failed, pids},
       exit_code,
       started,
       output
     )}
  end

  defp result(spec, status, reason, exit_code, started, output) do
    stdout = output["stdout"]
    stderr = output["stderr"]

    %{
      "name" => spec.name,
      "category" => spec.category,
      "status" => status,
      "reason" => reason && inspect(reason),
      "exit_code" => exit_code,
      "duration_ms" => max(System.monotonic_time(:millisecond) - started, 0),
      "command_spec_digest" => spec.digest,
      "runner_version" => @runner_version,
      "stdout_bytes" => stdout["bytes"],
      "stderr_bytes" => stderr["bytes"],
      "stdout_tail" => stdout["tail"],
      "stderr_tail" => stderr["tail"],
      "stdout_tail_encoding" => stdout["tail_encoding"],
      "stderr_tail_encoding" => stderr["tail_encoding"],
      "stdout_truncated" => stdout["truncated"],
      "stderr_truncated" => stderr["truncated"],
      "output_limit_bytes" => spec.output_limit_bytes,
      "output" => output
    }
  end

  defp capture_output(stdout, stderr, spec) do
    %{
      "stdout" => capture_stream(stdout, spec.output_limit_bytes, spec.tail_bytes),
      "stderr" => capture_stream(stderr, spec.output_limit_bytes, spec.tail_bytes)
    }
  end

  defp capture_stream(path, limit, tail_bytes) do
    bytes = file_size(path)
    prefix = read_slice(path, 0, min(bytes, limit))
    tail = read_slice(path, max(bytes - tail_bytes, 0), min(bytes, tail_bytes))
    {tail_text, tail_encoding} = printable(tail)

    %{
      "bytes" => bytes,
      "captured_bytes" => byte_size(prefix),
      "captured_base64" => Base.encode64(prefix),
      "tail" => tail_text,
      "tail_encoding" => tail_encoding,
      "truncated" => bytes > byte_size(prefix)
    }
  end

  defp empty_output(spec) do
    stream = %{
      "bytes" => 0,
      "captured_bytes" => 0,
      "captured_base64" => "",
      "tail" => "",
      "tail_encoding" => "utf-8",
      "truncated" => false
    }

    %{"stdout" => stream, "stderr" => stream, "limit" => spec.output_limit_bytes}
  end

  defp read_slice(_path, _offset, 0), do: ""

  defp read_slice(path, offset, length) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        :file.position(io, offset)
        body = IO.binread(io, length)
        File.close(io)
        if is_binary(body), do: body, else: ""

      {:error, _reason} ->
        ""
    end
  end

  defp printable(body) do
    if String.valid?(body), do: {body, "utf-8"}, else: {Base.encode64(body), "base64"}
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      {:error, _reason} -> 0
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp fallback_spec(attrs) do
    %CommandSpec{
      name: value(attrs, :name) || "invalid",
      category: value(attrs, :category) || "repository",
      argv: [],
      working_directory: ".",
      environment_allowlist: [],
      environment: %{},
      timeout_ms: 1,
      output_limit_bytes: 1,
      tail_bytes: 1,
      expected_exit_codes: [0],
      risk: "read",
      shell: false,
      reviewed: false,
      digest: "invalid"
    }
  end

  defp value(map, key), do: Map.get(Map.new(map), key) || Map.get(Map.new(map), to_string(key))
end
