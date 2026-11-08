defmodule Lightpath.Diagnosis do
  @moduledoc """
  Ranks the possible causes of a problem with Bayes' rule, from facts.

  A rule (one JSON file under `priv/rules/`) describes one problem:

    * `trigger`: the fact condition that says the problem is present;
    * `causes`: mutually exclusive root causes, each with a `prior`;
    * `other_prior`: the prior of "something else", always above zero so the
      ranking never claims certainty;
    * `evidence`: conditions on facts, each with likelihood ratios (`lr`) per
      cause id (or `"other"`). A ratio says how many times more likely that
      evidence is if the cause is true; causes not listed get 1.

  A condition is `{"fact": name, "equals": value}`. It matches only when the
  fact is known and equal; an unknown fact never matches, so missing
  evidence leaves the ranking alone instead of counting as false.
  """

  defmodule Cause do
    @moduledoc "One ranked cause: its probability and the evidence that moved it."
    defstruct [:id, :title, :why, :prior, :probability, contributions: []]

    @type t :: %__MODULE__{
            id: String.t(),
            title: String.t(),
            why: String.t() | nil,
            prior: float(),
            probability: float(),
            contributions: [{evidence_id :: String.t(), ratio :: number()}]
          }
  end

  defmodule Rule do
    @moduledoc "A parsed, validated rule."
    defstruct [:id, :title, :trigger, :causes, :other_prior, :evidence, :status, sources: []]

    @type t :: %__MODULE__{}
  end

  @doc """
  Parses and validates a rule from a decoded JSON map.

  Returns `{:error, reason}` (a readable string) when: an id is missing or
  duplicated among causes; a prior is not a number in (0, 1); `other_prior`
  is missing or not in (0, 1); the priors plus `other_prior` do not sum to 1
  (within 1.0e-6); an evidence entry has no `when` condition; or a
  likelihood ratio is not a positive number or names a cause that does not
  exist (other than `"other"`).
  """
  @spec parse(map()) :: {:ok, Rule.t()} | {:error, String.t()}
  def parse(%{} = map) do
    with {:ok, causes} <- parse_causes(map["causes"]),
         {:ok, other} <- probability(map["other_prior"], "other_prior"),
         :ok <- check_sum(causes, other),
         ids = MapSet.new(["other" | Enum.map(causes, & &1.id)]),
         {:ok, evidence} <- parse_evidence(map["evidence"] || [], ids),
         {:ok, trigger} <- condition(map["trigger"], "trigger") do
      {:ok,
       %Rule{
         id: map["id"],
         title: map["title"],
         status: map["status"],
         sources: map["sources"] || [],
         trigger: trigger,
         causes: causes,
         other_prior: other,
         evidence: evidence
       }}
    end
  end

  defp parse_causes(list) when is_list(list) and list != [] do
    Enum.reduce_while(list, {:ok, [], MapSet.new()}, fn c, {:ok, acc, seen} ->
      id = c["id"]

      cond do
        not is_binary(id) or id == "" ->
          {:halt, {:error, "a cause has no id"}}

        id == "other" or MapSet.member?(seen, id) ->
          {:halt, {:error, "cause id #{inspect(id)} is duplicated or reserved"}}

        true ->
          case probability(c["prior"], "prior of #{id}") do
            {:ok, p} ->
              cause = %Cause{id: id, title: c["title"] || id, why: c["why"], prior: p}
              {:cont, {:ok, [cause | acc], MapSet.put(seen, id)}}

            error ->
              {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, causes, _} -> {:ok, Enum.reverse(causes)}
      error -> error
    end
  end

  defp parse_causes(_), do: {:error, "causes must be a non-empty list"}

  defp probability(p, _what) when is_number(p) and p > 0 and p < 1, do: {:ok, p * 1.0}

  defp probability(p, what),
    do: {:error, "#{what} must be a number between 0 and 1, got #{inspect(p)}"}

  defp check_sum(causes, other) do
    total = Enum.reduce(causes, other, &(&1.prior + &2))

    if abs(total - 1.0) <= 1.0e-6,
      do: :ok,
      else: {:error, "priors plus other_prior sum to #{total}, not 1"}
  end

  defp parse_evidence(list, ids) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn e, {:ok, acc} ->
      with {:ok, _} <- condition(e["when"], "evidence #{inspect(e["id"])}"),
           :ok <- check_ratios(e["lr"] || %{}, ids, e["id"]) do
        {:cont, {:ok, [e | acc]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, evidence} -> {:ok, Enum.reverse(evidence)}
      error -> error
    end
  end

  defp parse_evidence(_, _), do: {:error, "evidence must be a list"}

  defp condition(%{"fact" => fact} = c, _what) when is_binary(fact) and is_map_key(c, "equals"),
    do: {:ok, c}

  defp condition(_, what),
    do: {:error, "#{what} needs a condition {\"fact\": ..., \"equals\": ...}"}

  defp check_ratios(lr, ids, ev_id) when is_map(lr) do
    Enum.find_value(lr, :ok, fn {cause, ratio} ->
      cond do
        not MapSet.member?(ids, cause) ->
          {:error, "evidence #{inspect(ev_id)} names unknown cause #{inspect(cause)}"}

        not (is_number(ratio) and ratio > 0) ->
          {:error, "evidence #{inspect(ev_id)}: ratio for #{cause} must be positive"}

        true ->
          nil
      end
    end)
  end

  defp check_ratios(_, _, ev_id), do: {:error, "evidence #{inspect(ev_id)}: lr must be an object"}

  @doc "Reads and parses every `*.json` rule in `dir`, sorted by file name."
  @spec load_all(Path.t()) :: {:ok, [Rule.t()]} | {:error, String.t()}
  def load_all(dir) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      with {:ok, data} <- File.read(path),
           {:ok, map} <- JSON.decode(data),
           {:ok, rule} <- parse(map) do
        {:cont, {:ok, [rule | acc]}}
      else
        {:error, reason} when is_binary(reason) ->
          {:halt, {:error, "#{Path.basename(path)}: #{reason}"}}

        {:error, reason} ->
          {:halt, {:error, "#{Path.basename(path)}: #{inspect(reason)}"}}
      end
    end)
    |> case do
      {:ok, rules} -> {:ok, Enum.reverse(rules)}
      error -> error
    end
  end

  @doc "True when the rule's trigger condition matches `facts`."
  @spec applies?(Rule.t(), map()) :: boolean()
  def applies?(%Rule{trigger: trigger}, facts), do: matches?(trigger, facts)

  defp matches?(%{"fact" => fact, "equals" => value}, facts) do
    Map.has_key?(facts, fact) and Map.fetch!(facts, fact) == value
  end

  @doc """
  Ranks the rule's causes plus "something else" (id `"other"`) given `facts`.

  Each probability is prior × the product of the ratios of all matching
  evidence, normalised so they sum to 1. Results are sorted by probability,
  highest first; ties keep the rule's order, with `"other"` last. Each
  cause's `contributions` lists the matching evidence that applied a ratio
  other than 1 to it, in the rule's evidence order. With no matching
  evidence, probabilities equal the priors.
  """
  @spec score(Rule.t(), map()) :: [Cause.t()]
  def score(%Rule{} = rule, facts) do
    matching = matching_evidence(rule, facts)
    other = %Cause{id: "other", title: "Something else", prior: rule.other_prior}

    weighted =
      for cause <- rule.causes ++ [other] do
        contributions =
          for e <- matching,
              ratio = Map.get(e["lr"] || %{}, cause.id, 1),
              ratio != 1,
              do: {e["id"], ratio}

        weight = Enum.reduce(contributions, cause.prior, fn {_, r}, acc -> acc * r end)
        {%{cause | contributions: contributions}, weight}
      end

    total = weighted |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    weighted
    |> Enum.map(fn {cause, w} -> %{cause | probability: w / total} end)
    # Enum.sort_by is stable, so ties keep rule order with "other" last.
    |> Enum.sort_by(& &1.probability, :desc)
  end

  @doc "The evidence entries of `rule` whose condition matches `facts`, in rule order."
  @spec matching_evidence(Rule.t(), map()) :: [map()]
  def matching_evidence(%Rule{evidence: evidence}, facts) do
    Enum.filter(evidence, &matches?(&1["when"], facts))
  end
end
