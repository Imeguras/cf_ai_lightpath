defmodule Lightpath.Packages do
  @moduledoc "Installed package names, read from the evidence (`pacman -Q`)."

  alias Lightpath.Fixtures

  @doc """
  The package names in `set`'s `pacman-q` fixture (one `name version` per
  line), sorted and without duplicates. `[]` when the fixture is missing or
  did not succeed.
  """
  @spec names(Fixtures.Set.t()) :: [String.t()]
  def names(set) do
    case Fixtures.get(set, "pacman-q") do
      {:ok, %{exit_code: 0} = f} ->
        for(line <- String.split(f.stdout, "\n"), [name | _] <- [String.split(line)], do: name)
        |> Enum.uniq()
        |> Enum.sort()

      _ ->
        []
    end
  end
end
