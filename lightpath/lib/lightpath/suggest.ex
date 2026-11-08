defmodule Lightpath.Suggest do
  @moduledoc """
  The question behind "Suggest a fix": the scored diagnosis, handed to the
  model as fixed context so it explains and plans instead of guessing.
  """

  alias Lightpath.Diagnosis.{Cause, Rule}

  @doc """
  The chat message for `rule`'s ranked `causes` (as `Diagnosis.score/2`
  returns them), with `runbook` (the top cause's runbook text, or nil).

  It says the ranking was computed by fixed rules from the evidence and
  must not be replaced by the model's own; names the problem (the rule's
  title); lists every cause in order with its percentage (one decimal) and
  the titles of the evidence that moved it (`evidence` maps evidence id to
  its entry); includes the runbook when there is one, saying a person wrote
  it; and asks for the next step for the top cause in at most 120 words,
  and what evidence would change the ranking if the model thinks it is
  wrong.
  """
  @spec message(Rule.t(), [Cause.t()], %{String.t() => map()}, String.t() | nil) :: String.t()
  def message(%Rule{} = rule, causes, evidence, runbook) do
    ranking =
      causes
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {c, i} ->
        moved = Enum.map(c.contributions, fn {id, _} -> evidence[id]["title"] end)
        because = if moved == [], do: "", else: " (evidence: #{Enum.join(moved, "; ")})"

        "#{i}. #{c.title}: #{:erlang.float_to_binary(c.probability * 100, decimals: 1)}%#{because}"
      end)

    runbook_part =
      if runbook,
        do: "\n\nRunbook for the top cause, written by the operator:\n#{runbook}",
        else: ""

    """
    A problem on my homelab server was diagnosed by fixed rules from recorded \
    evidence. Do not re-rank the causes or replace the ranking with your own.

    Problem: #{rule.title}

    Ranked causes:
    #{ranking}#{runbook_part}

    In at most 120 words, suggest the next step for the top cause. If you \
    think the ranking is wrong, say which evidence would change it.\
    """
  end
end
