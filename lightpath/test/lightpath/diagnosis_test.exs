defmodule Lightpath.DiagnosisTest do
  use ExUnit.Case, async: true

  alias Lightpath.Diagnosis
  alias Lightpath.Diagnosis.Cause

  @moduletag :tmp_dir

  defp rule_map(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "disk-full",
        "title" => "Writes fail",
        "status" => "unreviewed",
        "trigger" => %{"fact" => "writes.failing", "equals" => true},
        "causes" => [
          %{"id" => "full", "title" => "Filesystem full", "prior" => 0.5},
          %{"id" => "readonly", "title" => "Mounted read-only", "prior" => 0.3}
        ],
        "other_prior" => 0.2,
        "evidence" => [
          %{
            "id" => "df-100",
            "title" => "df shows 100%",
            "when" => %{"fact" => "df.full", "equals" => true},
            "lr" => %{"full" => 10, "readonly" => 0.5}
          },
          %{
            "id" => "ro-mount",
            "title" => "mount shows ro",
            "when" => %{"fact" => "mount.ro", "equals" => true},
            "lr" => %{"readonly" => 20, "other" => 0.5}
          }
        ]
      },
      overrides
    )
  end

  defp rule!(overrides \\ %{}) do
    {:ok, rule} = Diagnosis.parse(rule_map(overrides))
    rule
  end

  defp prob(causes, id), do: Enum.find(causes, &(&1.id == id)).probability

  describe "parse/1" do
    test "accepts a valid rule" do
      assert {:ok, rule} = Diagnosis.parse(rule_map())
      assert rule.id == "disk-full"
      assert length(rule.causes) == 2
    end

    test "rejects priors that do not sum to 1" do
      assert {:error, msg} = Diagnosis.parse(rule_map(%{"other_prior" => 0.3}))
      assert is_binary(msg)
    end

    test "rejects a missing or zero other_prior" do
      assert {:error, _} = Diagnosis.parse(Map.delete(rule_map(), "other_prior"))

      zero =
        rule_map(%{
          "other_prior" => 0,
          "causes" => [
            %{"id" => "full", "title" => "x", "prior" => 0.7},
            %{"id" => "readonly", "title" => "y", "prior" => 0.3}
          ]
        })

      assert {:error, _} = Diagnosis.parse(zero)
    end

    test "rejects duplicate or missing cause ids and bad priors" do
      dup = [
        %{"id" => "a", "title" => "x", "prior" => 0.4},
        %{"id" => "a", "title" => "y", "prior" => 0.4}
      ]

      assert {:error, _} = Diagnosis.parse(rule_map(%{"causes" => dup}))

      missing = [%{"title" => "x", "prior" => 0.8}]
      assert {:error, _} = Diagnosis.parse(rule_map(%{"causes" => missing}))

      bad = [
        %{"id" => "a", "title" => "x", "prior" => 1.2},
        %{"id" => "b", "title" => "y", "prior" => -0.4}
      ]

      assert {:error, _} = Diagnosis.parse(rule_map(%{"causes" => bad}))
    end

    test "rejects ratios that are not positive or name unknown causes" do
      for lr <- [%{"full" => 0}, %{"full" => -2}, %{"full" => "big"}, %{"nope" => 2}] do
        ev = [
          %{"id" => "e", "title" => "e", "when" => %{"fact" => "f", "equals" => true}, "lr" => lr}
        ]

        assert {:error, _} = Diagnosis.parse(rule_map(%{"evidence" => ev})),
               "accepted lr #{inspect(lr)}"
      end
    end

    test "rejects evidence without a condition" do
      ev = [%{"id" => "e", "title" => "e", "lr" => %{"full" => 2}}]
      assert {:error, _} = Diagnosis.parse(rule_map(%{"evidence" => ev}))
    end
  end

  test "load_all/1 reads every rule file in name order", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "b.json"), JSON.encode!(rule_map(%{"id" => "b"})))
    File.write!(Path.join(tmp, "a.json"), JSON.encode!(rule_map(%{"id" => "a"})))
    File.write!(Path.join(tmp, "notes.txt"), "ignored")
    assert {:ok, [%{id: "a"}, %{id: "b"}]} = Diagnosis.load_all(tmp)

    File.write!(Path.join(tmp, "c.json"), JSON.encode!(rule_map(%{"other_prior" => 0.9})))
    assert {:error, _} = Diagnosis.load_all(tmp)
  end

  test "applies?/2 follows the trigger, and an unknown fact never matches" do
    rule = rule!()
    assert Diagnosis.applies?(rule, %{"writes.failing" => true})
    refute Diagnosis.applies?(rule, %{"writes.failing" => false})
    refute Diagnosis.applies?(rule, %{})

    on_null = rule!(%{"trigger" => %{"fact" => "maybe", "equals" => nil}})
    refute Diagnosis.applies?(on_null, %{}), "an unknown fact matched a null condition"
    assert Diagnosis.applies?(on_null, %{"maybe" => nil})
  end

  describe "score/2" do
    test "with no matching evidence, probabilities are the priors" do
      causes = Diagnosis.score(rule!(), %{})
      assert_in_delta prob(causes, "full"), 0.5, 1.0e-9
      assert_in_delta prob(causes, "readonly"), 0.3, 1.0e-9
      assert_in_delta prob(causes, "other"), 0.2, 1.0e-9
      assert Enum.all?(causes, &(&1.contributions == []))
    end

    test "applies Bayes with likelihood ratios and normalises" do
      # full: 0.5*10 = 5, readonly: 0.3*0.5 = 0.15, other: 0.2 -> total 5.35
      causes = Diagnosis.score(rule!(), %{"df.full" => true})
      assert_in_delta prob(causes, "full"), 5 / 5.35, 1.0e-9
      assert_in_delta prob(causes, "readonly"), 0.15 / 5.35, 1.0e-9
      assert_in_delta prob(causes, "other"), 0.2 / 5.35, 1.0e-9
      assert_in_delta Enum.sum(Enum.map(causes, & &1.probability)), 1.0, 1.0e-9
    end

    test "multiplies the ratios of all matching evidence" do
      # full: 0.5*10*1 = 5, readonly: 0.3*0.5*20 = 3, other: 0.2*1*0.5 = 0.1 -> 8.1
      causes = Diagnosis.score(rule!(), %{"df.full" => true, "mount.ro" => true})
      assert_in_delta prob(causes, "readonly"), 3 / 8.1, 1.0e-9
      assert_in_delta prob(causes, "other"), 0.1 / 8.1, 1.0e-9
    end

    test "false or unknown facts do not match" do
      assert Diagnosis.score(rule!(), %{"df.full" => false}) == Diagnosis.score(rule!(), %{})
    end

    test "sorts by probability and records contributions" do
      [first | _] = causes = Diagnosis.score(rule!(), %{"mount.ro" => true})
      assert %Cause{id: "readonly"} = first
      assert first.contributions == [{"ro-mount", 20}]

      assert Enum.map(causes, & &1.probability) ==
               Enum.sort(Enum.map(causes, & &1.probability), :desc)

      other = Enum.find(causes, &(&1.id == "other"))
      assert other.title != nil
      assert other.contributions == [{"ro-mount", 0.5}]
      full = Enum.find(causes, &(&1.id == "full"))
      assert full.contributions == []
    end

    test "ties keep rule order with other last" do
      tie =
        rule!(%{
          "causes" => [
            %{"id" => "a", "title" => "a", "prior" => 0.4},
            %{"id" => "b", "title" => "b", "prior" => 0.4}
          ],
          "other_prior" => 0.2,
          "evidence" => []
        })

      even =
        rule!(%{
          "causes" => [%{"id" => "a", "title" => "a", "prior" => 0.5}],
          "other_prior" => 0.5,
          "evidence" => []
        })

      assert Enum.map(Diagnosis.score(tie, %{}), & &1.id) == ["a", "b", "other"]
      assert Enum.map(Diagnosis.score(even, %{}), & &1.id) == ["a", "other"]
    end
  end

  test "matching_evidence/2 lists matching entries in rule order" do
    ids =
      Diagnosis.matching_evidence(rule!(), %{"mount.ro" => true, "df.full" => true})
      |> Enum.map(& &1["id"])

    assert ids == ["df-100", "ro-mount"]
  end
end
