defmodule Mix.Tasks.Husky.Execute do
  import IO.ANSI

  @moduledoc """
  Mix task to invoke a system command set by a husky config file

  ## Examples
  With the given config file:
  ```elixir
  config :husky, pre_commit: "mix format"
  ```

  ```bash
  mix husky.execute pre-commit
  ```
  Would execute `mix format`
  """

  use Mix.Task
  @defaults %{config: nil}

  @doc """
  mix task to execute husky config commands.

  ## Examples
  `mix husky.execute pre-commit`
  """
  def run(argv) do
    argv
    |> parse_args()
    |> elem(0)
    |> process_options()

    command =
      argv
      |> parse_args()
      |> fetch_command()

    case command do
      {:error, :no_cmd} ->
        System.halt()

      {:ok, {hook, cmd}} ->
        running_message()

        cmd
        |> execute_cmd()
        |> handle_result(%{hook: hook, cmd: cmd})
    end
  end

  defp process_options(options) do
    %{config: config} = Enum.into(options, @defaults)

    if !is_nil(config) do
      Mix.Task.run("loadconfig", [config])
    end
  end

  defp handle_result({0, out}, %{hook: hook, cmd: cmd}) do
    """
    #{out}
    #{green()}
    husky > #{print_hook(hook)} ('#{cmd}')
    #{reset()}
    """
    |> IO.puts()

    System.halt()
  end

  defp handle_result({code, out}, %{hook: hook, cmd: cmd}) do
    """
    #{out}
    #{red()}
    husky > #{print_hook(hook)} ('#{cmd}') failed #{no_verify_message(hook)}
    #{reset()}
    """
    |> IO.puts()

    System.halt(code)
  end

  defp print_hook(hook) when is_list(hook) and length(hook) > 1 do
    hook
    |> Enum.join(" ")
    |> String.trim()
  end

  defp print_hook(hook), do: hook

  defp no_verify_message(hook) do
    if List.first(hook) in [
         "commit-msg",
         "pre-commit",
         "pre-rebase",
         "pre-push"
       ] do
      "(add --no-verify to bypass)"
    else
      "(cannot be bypassed with --no-verify due to Git specs)"
    end
  end

  defp running_message do
    """
    🐶
    .... running husky hook
    """
    |> IO.puts()
  end

  defp parse_args(argv) do
    # { keyword list of parsed switches, list of the remaining arguments in argv, a list of invalid options}
    {parsed, args, _} =
      argv
      |> OptionParser.parse(
        switches: [upcase: :boolean, config: :string],
        aliases: [u: :upcase, c: :config]
      )

    {parsed, args}
  end

  defp fetch_command({_, word}) do
    # {[upcase: true], ["pre-push", "origin", "https://github.com/spencerdcarlson/husky-elixir.git"]} # example args
    command =
      word
      |> List.first()
      |> normalize()
      |> config()

    case command do
      {:ok, cmd} -> {:ok, {word, cmd}}
      {:error, :config} -> {:error, :no_cmd}
    end
  end

  defp execute_cmd(cmd) do
    result =
      case :os.type() do
        {:win32, _} ->
          "cmd /V:ON /c \"(#{cmd}) & echo !errorlevel!\""

        _ ->
          "#{cmd}; echo $?"
      end
      |> to_charlist()
      |> :os.cmd()
      |> to_string()

    {code, out} =
      result
      |> String.split("\n")
      |> List.pop_at(-2)

    {String.to_integer(String.trim(code)), Enum.join(out, "\n")}
  end

  defp config(key) do
    # source list order determines value precedence. - See Map.merge/2
    # If there are conflicting keys in multiple configuration files last item in the source list will take precedence.
    # if config :husky, pre_commit: "mix format" exists in config/config.exs and
    # { "husky": { "hooks": { "pre_commit": "npm test" } } }
    # is in .husky.json, then which ever file is last in the sources list will determine the value for pre_commit

    # get all config files
    # list of tuples { config_exists?, %{configs} }
    configs =
      [json_config(), elixir_config()]
      |> Stream.filter(&elem(&1, 0))
      |> Stream.map(&elem(&1, 1))
      |> Enum.reduce(%{}, &Map.merge(&2, &1))

    if Map.has_key?(configs, key), do: {:ok, configs[key]}, else: {:error, :config}
  end

  defp elixir_config do
    envs = Application.get_all_env(:husky)

    if Enum.empty?(envs) do
      {false, %{}}
    else
      {true, Map.new(envs)}
    end
  end

  defp json_config do
    if File.exists?(".husky.json") do
      {true, parse_json(".husky.json")}
    else
      {false, %{}}
    end
  end

  defp parse_json(file) do
    with {:module, parser} <-
           Code.ensure_loaded(Application.get_env(:husky, :json_codec, Poison)),
         {:ok, body} <- File.read(file),
         {:ok, json} <- parser.decode(body) do
      normalize(json["husky"]["hooks"])
    else
      {:error, reason} ->
        """
        #{yellow()}
        husky > JSON parsing failed
          Ensure that either Poison is available or that :json_codec is set and is available
          Error: #{inspect(reason)}
        #{reset()}
        """
        |> IO.puts()

        %{}
    end
  end

  defp normalize(map) when is_map(map) do
    for {key, value} <- map, into: %{} do
      if is_map(value), do: {normalize(key), normalize(value)}, else: {normalize(key), value}
    end
  end

  defp normalize(key) when is_binary(key) do
    key
    |> String.replace("-", "_")
    |> String.to_atom()
  end
end
