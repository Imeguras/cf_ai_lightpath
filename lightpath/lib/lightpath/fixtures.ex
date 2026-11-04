defmodule Lightpath.Fixtures do
  @moduledoc """
  Reads a public fixture set, as written by `probe/cmd/scrub`.

  A fixture set is a directory with an `index.json` manifest and one
  `<id>.json` file per command. The root directory holds one set per
  subdirectory.
  """

  defmodule Fixture do
    @moduledoc "One recorded command and what it printed."
    defstruct [
      :id,
      :argv,
      :exit_code,
      :stdout,
      :stderr,
      :error,
      :timed_out,
      :truncated,
      :started_at,
      :duration_ms
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            argv: [String.t()],
            exit_code: integer(),
            stdout: String.t(),
            stderr: String.t(),
            error: String.t(),
            timed_out: boolean(),
            truncated: boolean(),
            started_at: String.t(),
            duration_ms: non_neg_integer()
          }
  end

  defmodule Set do
    @moduledoc "A fixture set: where it came from and its fixtures, in manifest order."
    defstruct [:name, :target, :created_at, fixtures: []]

    @type t :: %__MODULE__{
            name: String.t(),
            target: String.t(),
            created_at: String.t(),
            fixtures: [Lightpath.Fixtures.Fixture.t()]
          }
  end

  @doc """
  Loads the set in `dir`. The set's `name` is the directory's base name, and
  fixtures come in the order the manifest lists them. Missing optional
  fields read as empty strings, `false` or `0`.

  Returns `{:error, :no_manifest}` when `dir` has no `index.json`,
  `{:error, :bad_manifest}` when it is not valid JSON, and
  `{:error, {:bad_fixture, id}}` when a listed fixture file is missing or
  unreadable.
  """
  @spec load(Path.t()) :: {:ok, Set.t()} | {:error, term()}
  def load(dir) do
    with {:ok, manifest} <- read_manifest(dir),
         {:ok, fixtures} <- read_fixtures(dir, Map.get(manifest, "entries") || []) do
      {:ok,
       %Set{
         name: Path.basename(dir),
         target: Map.get(manifest, "target", ""),
         created_at: Map.get(manifest, "created_at", ""),
         fixtures: fixtures
       }}
    end
  end

  defp read_manifest(dir) do
    case File.read(Path.join(dir, "index.json")) do
      {:ok, data} ->
        case JSON.decode(data) do
          {:ok, %{} = manifest} -> {:ok, manifest}
          _ -> {:error, :bad_manifest}
        end

      {:error, _} ->
        {:error, :no_manifest}
    end
  end

  defp read_fixtures(dir, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      id = Map.get(entry, "id", "")
      file = Map.get(entry, "file", id <> ".json")

      with {:ok, data} <- File.read(Path.join(dir, Path.basename(file))),
           {:ok, %{} = r} <- JSON.decode(data) do
        {:cont, {:ok, [to_fixture(r) | acc]}}
      else
        _ -> {:halt, {:error, {:bad_fixture, id}}}
      end
    end)
    |> case do
      {:ok, fixtures} -> {:ok, Enum.reverse(fixtures)}
      error -> error
    end
  end

  defp to_fixture(r) do
    %Fixture{
      id: Map.get(r, "id", ""),
      argv: Map.get(r, "argv") || [],
      exit_code: Map.get(r, "exit_code", 0),
      stdout: Map.get(r, "stdout") || "",
      stderr: Map.get(r, "stderr") || "",
      error: Map.get(r, "error") || "",
      timed_out: Map.get(r, "timed_out", false),
      truncated: Map.get(r, "truncated", false),
      started_at: Map.get(r, "started_at") || "",
      duration_ms: Map.get(r, "duration_ms") || 0
    }
  end

  @doc """
  Returns the fixture with `id` from `set`.

  `{:error, :not_found}` when the set has no such fixture.
  """
  @spec get(Set.t(), String.t()) :: {:ok, Fixture.t()} | {:error, :not_found}
  def get(%Set{fixtures: fixtures}, id) do
    case Enum.find(fixtures, &(&1.id == id)) do
      nil -> {:error, :not_found}
      fixture -> {:ok, fixture}
    end
  end

  @doc """
  Finds the newest set under `root`: the subdirectory whose manifest has the
  latest `created_at`. Subdirectories without a readable manifest are
  ignored.

  Returns `{:error, :no_sets}` when there is none, including when `root`
  does not exist.
  """
  @spec latest(Path.t()) :: {:ok, Set.t()} | {:error, :no_sets}
  def latest(root) do
    sets =
      case File.ls(root) do
        {:ok, names} ->
          for name <- names,
              dir = Path.join(root, name),
              File.dir?(dir),
              {:ok, set} <- [load(dir)],
              do: set

        {:error, _} ->
          []
      end

    case sets do
      [] -> {:error, :no_sets}
      sets -> {:ok, Enum.max_by(sets, & &1.created_at)}
    end
  end

  @doc """
  Classifies a fixture for display:

    * `:ok` - it ran and exited 0
    * `:failed` - it ran and exited non-zero (often the evidence itself)
    * `:not_run` - it never produced an exit code: it timed out or could not
      be started (`error` is set)
  """
  @spec status(Fixture.t()) :: :ok | :failed | :not_run
  def status(%Fixture{timed_out: true}), do: :not_run
  def status(%Fixture{error: error}) when is_binary(error) and error != "", do: :not_run
  def status(%Fixture{exit_code: 0}), do: :ok
  def status(%Fixture{}), do: :failed
end
