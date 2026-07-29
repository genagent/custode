defmodule Custode.Verification.Runner do
  @moduledoc """
  Shell-free argv runner with bounded output, timeout, and process-tree cleanup.

  A fixed private shell helper performs only stdout/stderr redirection before
  `exec`. Command text is never interpolated or evaluated by that helper.
  """

  alias Custode.Verification.CommandSpec

  @runner_version "verification-runner-v1"
  @poll_ms 10
  @kill_grace_ms 50
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
         {:ok, port} <- open_port(spec, runtime, stdout, stderr) do
      os_pid = port_pid(port)
      deadline = started + spec.timeout_ms
      forced = await(port, os_pid, stdout, stderr, spec, deadline, options)
      output = capture_output(stdout, stderr, spec)
      File.rm_rf(directory)
      finish_execution(spec, forced, started, output)
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

  defp open_port(spec, runtime, stdout, stderr) do
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

  defp port_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp await(port, os_pid, stdout, stderr, spec, deadline, options) do
    receive do
      {^port, {:exit_status, status}} ->
        {:exit, status}

      {^port, :eof} ->
        await(port, os_pid, stdout, stderr, spec, deadline, options)

      {^port, {:data, _unexpected}} ->
        await(port, os_pid, stdout, stderr, spec, deadline, options)
    after
      @poll_ms ->
        cond do
          cancelled?(options) ->
            terminate(port, os_pid)
            {:forced, "cancellation", :cancelled}

          System.monotonic_time(:millisecond) >= deadline ->
            terminate(port, os_pid)
            {:forced, "timeout", :timeout}

          output_limit_exceeded?(stdout, stderr, spec.output_limit_bytes) ->
            terminate(port, os_pid)
            {:forced, "policy_refusal", :output_limit_exceeded}

          true ->
            await(port, os_pid, stdout, stderr, spec, deadline, options)
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

  defp terminate(port, nil) do
    close_port(port)
  end

  defp terminate(port, root_pid) do
    signal([root_pid], "-STOP")

    pids =
      Enum.reduce(1..3, MapSet.new([root_pid]), fn _iteration, known ->
        observed = descendants(root_pid) |> MapSet.new() |> MapSet.union(known)
        signal(MapSet.to_list(observed), "-STOP")
        observed
      end)
      |> MapSet.to_list()

    signal(Enum.reverse(pids), "-TERM")
    signal(pids, "-CONT")
    Process.sleep(@kill_grace_ms)
    signal(Enum.reverse(pids), "-KILL")
    close_port(port)
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp descendants(root_pid) do
    case System.cmd("ps", ["-axo", "pid=,ppid="], stderr_to_stdout: true) do
      {output, 0} ->
        children =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, &group_process/2)

        collect_descendants([root_pid], children, [])

      {_output, _status} ->
        []
    end
  end

  defp group_process(line, grouped) do
    case line |> String.split(~r/\s+/, trim: true) |> Enum.map(&Integer.parse/1) do
      [{pid, ""}, {parent, ""}] -> Map.update(grouped, parent, [pid], &[pid | &1])
      _invalid -> grouped
    end
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
