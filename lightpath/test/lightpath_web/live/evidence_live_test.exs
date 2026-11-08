defmodule LightpathWeb.EvidenceLiveTest do
  # Not async: each test points :fixtures_root at its own directory.
  use LightpathWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous =
      Map.new(
        [:fixtures_root, :worker, :fake_worker, :poll_ms, :probe, :fake_probe, :refresh_ms],
        &{&1, Application.get_env(:lightpath, &1)}
      )

    Application.put_env(:lightpath, :fixtures_root, tmp)
    Application.put_env(:lightpath, :probe, Lightpath.FakeProbe)
    Application.put_env(:lightpath, :fake_probe, %{test: self(), available?: false})
    Application.put_env(:lightpath, :refresh_ms, 60_000)
    Application.put_env(:lightpath, :worker, Lightpath.FakeWorker)
    Application.put_env(:lightpath, :fake_worker, %{test: self()})
    Application.put_env(:lightpath, :poll_ms, 5)

    on_exit(fn ->
      Enum.each(previous, fn
        {k, nil} -> Application.delete_env(:lightpath, k)
        {k, v} -> Application.put_env(:lightpath, k, v)
      end)
    end)

    :ok
  end

  defp write_set(root, name, results, created_at \\ "2026-11-04T17:32:40Z") do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)

    entries =
      for r <- results do
        File.write!(Path.join(dir, r["id"] <> ".json"), JSON.encode!(r))
        %{"id" => r["id"], "file" => r["id"] <> ".json", "exit_code" => r["exit_code"]}
      end

    File.write!(
      Path.join(dir, "index.json"),
      JSON.encode!(%{
        "target" => "labuser@192.0.2.1",
        "created_at" => created_at,
        "entries" => entries
      })
    )
  end

  defp zfs_set(root) do
    write_set(root, "zfs-down-2026-11-04", [
      %{
        "id" => "uname",
        "argv" => ["uname", "-a"],
        "exit_code" => 0,
        "stdout" => "Linux labhost 7.2.14-arch1-1"
      },
      %{
        "id" => "zpool-status",
        "argv" => ["zpool", "status"],
        "exit_code" => 1,
        "stderr" => "The ZFS modules cannot be auto-loaded."
      },
      %{
        "id" => "slow",
        "argv" => ["sleep", "99"],
        "exit_code" => -1,
        "timed_out" => true,
        "error" => "timed out after 30s"
      },
      %{
        "id" => "html",
        "argv" => ["echo"],
        "exit_code" => 0,
        "stdout" => "<script>alert(1)</script>"
      },
      %{
        "id" => "html-err",
        "argv" => ["echo", "<i>argv</i>"],
        "exit_code" => -1,
        "stderr" => "<img src=x onerror=alert(2)>",
        "error" => "<b>boom</b>"
      },
      %{
        "id" => "dmesg",
        "argv" => ["dmesg"],
        "exit_code" => 1,
        "stderr" => "dmesg: read kernel buffer failed: Operation not permitted"
      },
      %{
        "id" => "systemctl-kubelet",
        "argv" => ["systemctl", "status", "kubelet.service"],
        "exit_code" => 3,
        "stdout" => "Active: inactive (dead)"
      }
    ])
  end

  test "lists every fixture with the set header and counts", %{conn: conn, tmp_dir: tmp} do
    zfs_set(tmp)
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "zfs-down-2026-11-04"
    assert html =~ "2026-11-04"
    assert html =~ "labuser@192.0.2.1"
    for id <- ["uname", "zpool-status", "slow", "html", "html-err"], do: assert(html =~ id)

    doc = LazyHTML.from_fragment(html)
    assert LazyHTML.query(doc, ".lp-list .lp-kind--ok") |> Enum.count() == 2
    assert LazyHTML.query(doc, ".lp-list .lp-kind--failed") |> Enum.count() == 1
    assert LazyHTML.query(doc, ".lp-list .lp-kind--not-run") |> Enum.count() == 2
    assert LazyHTML.query(doc, ".lp-list .lp-kind--needs-privilege") |> Enum.count() == 1
    assert LazyHTML.query(doc, ".lp-list .lp-kind--inactive") |> Enum.count() == 1
  end

  test "counts say why commands did not succeed", %{conn: conn, tmp_dir: tmp} do
    zfs_set(tmp)
    {:ok, _view, html} = live(conn, ~p"/")
    counts = html |> LazyHTML.from_fragment() |> LazyHTML.query(".lp-counts") |> LazyHTML.text()
    assert counts =~ ~r/2\s*ok/
    assert counts =~ ~r/1\s*failed/
    assert counts =~ ~r/1\s*needs root/
    assert counts =~ ~r/1\s*inactive/
    assert counts =~ ~r/2\s*not run/
    refute counts =~ "not installed"
  end

  test "the detail chip names the kind", %{conn: conn, tmp_dir: tmp} do
    zfs_set(tmp)
    {:ok, _view, html} = live(conn, ~p"/?id=dmesg")
    assert html =~ "needs root"
  end

  describe "evidence sets" do
    test "the newest set by default, a picker for the others", %{conn: conn, tmp_dir: tmp} do
      write_set(
        tmp,
        "old-set",
        [%{"id" => "a", "argv" => ["a"], "exit_code" => 1}],
        "2026-11-04T00:00:00Z"
      )

      write_set(
        tmp,
        "new-set",
        [%{"id" => "b", "argv" => ["b"], "exit_code" => 0}],
        "2026-11-08T00:00:00Z"
      )

      {:ok, view, html} = live(conn, ~p"/")

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".lp-set__name")
             |> LazyHTML.text() =~ "new-set"

      html = view |> element(~s{.lp-sets a[href="/?set=old-set"]}) |> render_click()
      assert_patch(view, ~p"/?set=old-set")

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".lp-set__name")
             |> LazyHTML.text() =~ "old-set"

      # Fixture links keep the chosen set.
      [href] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".lp-list a")
        |> LazyHTML.attribute("href")

      assert URI.decode_query(URI.parse(href).query) == %{"set" => "old-set", "id" => "a"}
    end

    test "an unknown set says so", %{conn: conn, tmp_dir: tmp} do
      zfs_set(tmp)
      {:ok, _view, html} = live(conn, ~p"/?set=nope")
      assert html =~ "No evidence set called"
      assert html =~ "nope"
    end
  end

  test "?id= shows the fixture's command, exit code and output", %{conn: conn, tmp_dir: tmp} do
    zfs_set(tmp)
    {:ok, _view, html} = live(conn, ~p"/?id=zpool-status")
    assert html =~ "zpool status"
    assert html =~ "The ZFS modules cannot be auto-loaded."
    assert html =~ "1"
  end

  test "a fixture that could not run shows its error", %{conn: conn, tmp_dir: tmp} do
    zfs_set(tmp)
    {:ok, _view, html} = live(conn, ~p"/?id=slow")
    assert html =~ "timed out after 30s"
  end

  test "clicking a fixture selects it without a full reload", %{conn: conn, tmp_dir: tmp} do
    zfs_set(tmp)
    {:ok, view, _html} = live(conn, ~p"/")
    html = view |> element(~s{a[href="/?id=uname"]}) |> render_click()
    assert_patch(view, ~p"/?id=uname")
    assert html =~ "Linux labhost 7.2.14-arch1-1"
  end

  test "an unknown id shows a notice instead of crashing", %{conn: conn, tmp_dir: tmp} do
    zfs_set(tmp)
    {:ok, _view, html} = live(conn, ~p"/?id=does-not-exist")
    assert html =~ "No fixture"
    assert html =~ "does-not-exist"
  end

  test "recorded output is escaped, never rendered as HTML", %{conn: conn, tmp_dir: tmp} do
    zfs_set(tmp)
    {:ok, _view, html} = live(conn, ~p"/?id=html")
    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;"
  end

  test "stderr, error and the command line are escaped too", %{conn: conn, tmp_dir: tmp} do
    zfs_set(tmp)
    {:ok, _view, html} = live(conn, ~p"/?id=html-err")
    refute html =~ "<img src=x"
    refute html =~ "<b>boom</b>"
    refute html =~ "<i>argv</i>"
    assert html =~ "&lt;img src=x"
    assert html =~ "&lt;b&gt;boom&lt;/b&gt;"
    assert html =~ "&lt;i&gt;argv&lt;/i&gt;"
  end

  test "with no fixture set, the page explains how to make one", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "No fixture set"
    assert html =~ "scrub"
  end

  describe "diagnosis panel" do
    @public Path.expand("../../../../fixtures/public/zfs-down-2026-11-04", __DIR__)

    test "ranks causes for the recorded ZFS failure, with evidence links", %{
      conn: conn,
      tmp_dir: tmp
    } do
      File.ln_s!(@public, Path.join(tmp, "zfs-down-2026-11-04"))
      {:ok, _view, html} = live(conn, ~p"/")

      doc = LazyHTML.from_fragment(html)
      panel = LazyHTML.query(doc, ~s{.lp-diagnosis[data-rule="zfs-pools-unavailable"]})
      assert Enum.count(panel) == 1
      text = LazyHTML.text(panel)
      assert text =~ "ZFS pools are unavailable"
      assert text =~ "unreviewed"
      assert text =~ "%"

      {top, _} = :binary.match(text, "Running kernel is newer than zfs-dkms supports")
      {lower, _} = :binary.match(text, "dkms build failed for another reason")
      assert top < lower, "the kernel mismatch is not ranked first"

      assert text =~ "Running kernel is above zfs-dkms Linux-Maximum"
      links = LazyHTML.query(panel, ~s{a[href="/?id=zfs-dkms-meta"]})
      assert Enum.count(links) >= 1
    end

    test "every rule that applies gets its own panel", %{conn: conn, tmp_dir: tmp} do
      File.ln_s!(@public, Path.join(tmp, "zfs-down-2026-11-04"))
      {:ok, _view, html} = live(conn, ~p"/")
      doc = LazyHTML.from_fragment(html)

      for rule <- ["zfs-pools-unavailable", "kubelet-down", "ipmi-unavailable", "lan-slow"] do
        assert LazyHTML.query(doc, ~s{.lp-diagnosis[data-rule="#{rule}"]}) |> Enum.count() == 1,
               rule
      end
    end

    test "a cause's runbook is shown under it; causes without one say how to add it", %{
      conn: conn,
      tmp_dir: tmp
    } do
      File.ln_s!(@public, Path.join(tmp, "zfs-down-2026-11-04"))
      {:ok, _view, html} = live(conn, ~p"/")

      panel =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s{.lp-diagnosis[data-rule="zfs-pools-unavailable"]})

      runbook = LazyHTML.query(panel, ~s{[data-cause="kernel-unsupported"] .lp-runbook})
      assert LazyHTML.text(runbook) =~ "--assume-installed"

      other = LazyHTML.query(panel, ~s{[data-cause="dkms-build-failed"]}) |> LazyHTML.text()
      assert other =~ "priv/runbooks/zfs-pools-unavailable/dkms-build-failed.md"
    end

    test "Suggest a fix asks the triage Workflow with the scored ranking and shows the answer", %{
      conn: conn,
      tmp_dir: tmp
    } do
      File.ln_s!(@public, Path.join(tmp, "zfs-down-2026-11-04"))
      {:ok, view, _} = live(conn, ~p"/")

      view
      |> element(~s{.lp-diagnosis[data-rule="zfs-pools-unavailable"] button}, "Suggest a fix")
      |> render_click()

      assert_receive {:worker, :triage, [visitor, session, message, false]}
      assert visitor =~ ~r/^[0-9a-f]{32}$/
      assert session =~ visitor
      assert message =~ "ZFS pools are unavailable"
      assert message =~ "97.5%"
      assert message =~ "--assume-installed", "the top cause's runbook goes along"
      assert_receive {:worker, :triage_status, [^visitor, "t-1"]}

      html = render_async(view) && render(view)

      panel =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s{.lp-diagnosis[data-rule="zfs-pools-unavailable"] .lp-ai})

      text = LazyHTML.text(panel)
      assert text =~ "Fake triage answer."
      assert text =~ "@cf/fake/large"
      assert text =~ "AI can make mistakes"
      assert text =~ "the small model suggested a command"
    end

    test "a failed suggestion is a notice", %{conn: conn, tmp_dir: tmp} do
      File.ln_s!(@public, Path.join(tmp, "zfs-down-2026-11-04"))

      Application.put_env(:lightpath, :fake_worker, %{
        test: self(),
        triage_status: {:ok, %{status: "errored", output: nil, error: "4006: allowance used up"}}
      })

      {:ok, view, _} = live(conn, ~p"/")

      view
      |> element(~s{.lp-diagnosis[data-rule="kubelet-down"] button}, "Suggest a fix")
      |> render_click()

      assert_receive {:worker, :triage_status, _}
      Process.sleep(20)
      assert render(view) =~ "4006: allowance used up"
    end

    test "a set that triggers no rule shows no panel", %{conn: conn, tmp_dir: tmp} do
      write_set(tmp, "healthy", [
        %{
          "id" => "uname",
          "argv" => ["uname"],
          "exit_code" => 0,
          "stdout" => "Linux h 6.18.3-arch1-1 x"
        }
      ])

      {:ok, _view, html} = live(conn, ~p"/")
      refute html =~ "lp-diagnosis"
    end
  end

  describe "Explain button" do
    setup %{tmp_dir: tmp} do
      zfs_set(tmp)
      :ok
    end

    test "explains the selected fixture for this visitor and labels the answer", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/?id=zpool-status")
      view |> element("button", "Explain") |> render_click()
      assert_receive {:worker, :explain, [%{id: "zpool-status"}, visitor]}
      assert visitor =~ ~r/^[0-9a-f]{32}$/

      html = render_async(view)
      assert html =~ "Fake explanation for zpool-status."
      assert html =~ "@cf/fake/model"
      assert html =~ ~r/AI-generated/i
      assert html =~ ~r/unscored/i
      assert html =~ "AI can make mistakes"
    end

    test "the answer is plain text, never HTML", %{conn: conn} do
      Application.put_env(:lightpath, :fake_worker, %{
        explain: {:ok, %{model: "m", text: "<b>bold</b> claim", neurons: 1}}
      })

      {:ok, view, _} = live(conn, ~p"/?id=uname")
      view |> element("button", "Explain") |> render_click()
      html = render_async(view)
      refute html =~ "<b>bold</b>"
      assert html =~ "&lt;b&gt;bold&lt;/b&gt; claim"
    end

    test "a failure is shown as a notice", %{conn: conn} do
      Application.put_env(:lightpath, :fake_worker, %{
        explain: {:error, "Workers AI failed: quota exceeded"}
      })

      {:ok, view, _} = live(conn, ~p"/?id=uname")
      view |> element("button", "Explain") |> render_click()
      assert render_async(view) =~ "quota exceeded"
    end

    test "answers stay with their fixture while the page is open", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/?id=uname")
      view |> element("button", "Explain") |> render_click()
      assert render_async(view) =~ "Fake explanation for uname."

      html = view |> element(~s{a[href="/?id=zpool-status"]}) |> render_click()
      refute html =~ "Fake explanation for uname."

      html = view |> element(~s{a[href="/?id=uname"]}) |> render_click()
      assert html =~ "Fake explanation for uname."
    end

    test "no AI buttons and no usage when the Worker is not available", %{conn: conn} do
      Application.put_env(:lightpath, :fake_worker, %{available?: false})
      {:ok, _view, html} = live(conn, ~p"/?id=uname")
      refute html =~ ">Explain"
      refute html =~ "Suggest a fix"
      refute html =~ "neurons"
    end
  end

  test "the header shows today's rough neuron estimate", %{conn: conn, tmp_dir: tmp} do
    zfs_set(tmp)
    {:ok, view, _} = live(conn, ~p"/")
    html = render_async(view)
    usage = html |> LazyHTML.from_fragment() |> LazyHTML.query(".lp-usage") |> LazyHTML.text()
    assert usage =~ "12"
    assert usage =~ "10,000"
    assert usage =~ ~r/rough/i
  end

  test "the header links the three pages", %{conn: conn, tmp_dir: tmp} do
    zfs_set(tmp)
    {:ok, _view, html} = live(conn, ~p"/")
    for href <- ["/", "/chat", "/news"], do: assert(html =~ ~s{href="#{href}"})
  end

  describe "live probe" do
    defp live_probe(extra \\ %{}),
      do: Application.put_env(:lightpath, :fake_probe, Map.merge(%{test: self()}, extra))

    test "without the daemon there is no Re-probe button and no timeline", %{
      conn: conn,
      tmp_dir: tmp
    } do
      zfs_set(tmp)
      {:ok, _view, html} = live(conn, ~p"/")
      refute html =~ "Re-probe now"
      refute html =~ "lp-timeline"
    end

    test "Re-probe now runs the daemon and shows the new set", %{conn: conn, tmp_dir: tmp} do
      zfs_set(tmp)

      live_probe(%{
        probe: fn ->
          write_set(
            tmp,
            "live-new",
            [%{"id" => "uname", "argv" => ["uname"], "exit_code" => 0}],
            "2026-11-09T00:00:00Z"
          )

          {:ok, "live-new"}
        end
      })

      {:ok, view, _} = live(conn, ~p"/")
      view |> element("button", "Re-probe now") |> render_click()
      assert_receive {:probe, :probe, []}
      html = render_async(view) && render(view)

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".lp-set__name")
             |> LazyHTML.text() =~ "live-new"
    end

    test "a failed re-probe is a notice", %{conn: conn, tmp_dir: tmp} do
      zfs_set(tmp)
      live_probe(%{probe: {:error, "a probe run is already in progress"}})
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("button", "Re-probe now") |> render_click()
      assert render_async(view) =~ "a probe run is already in progress"
    end

    test "the timeline shows recent events, newest first", %{conn: conn, tmp_dir: tmp} do
      zfs_set(tmp)
      live_probe()
      {:ok, view, _} = live(conn, ~p"/")
      assert_receive {:probe, :events, [%DateTime{}]}
      html = render_async(view)

      timeline =
        html |> LazyHTML.from_fragment() |> LazyHTML.query(".lp-timeline") |> LazyHTML.text()

      assert timeline =~ "kubelet.service"
      assert timeline =~ "failed"
      assert timeline =~ "linux"
      assert timeline =~ "upgraded"
      {k, _} = :binary.match(timeline, "kubelet.service")
      {l, _} = :binary.match(timeline, "upgraded")
      assert k < l, "newest first"
    end

    test "a new set appearing is picked up without a reload", %{conn: conn, tmp_dir: tmp} do
      zfs_set(tmp)
      {:ok, view, _} = live(conn, ~p"/")

      write_set(
        tmp,
        "live-later",
        [%{"id" => "uname", "argv" => ["uname"], "exit_code" => 0}],
        "2026-11-10T00:00:00Z"
      )

      send(view.pid, :refresh)
      html = render(view)

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".lp-set__name")
             |> LazyHTML.text() =~ "live-later"
    end

    test "when an older set is chosen, a new one is announced instead of switching", %{
      conn: conn,
      tmp_dir: tmp
    } do
      zfs_set(tmp)
      {:ok, view, _} = live(conn, ~p"/?set=zfs-down-2026-11-04")

      write_set(
        tmp,
        "live-later",
        [%{"id" => "uname", "argv" => ["uname"], "exit_code" => 0}],
        "2026-11-10T00:00:00Z"
      )

      send(view.pid, :refresh)
      html = render(view)

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".lp-set__name")
             |> LazyHTML.text() =~ "zfs-down-2026-11-04"

      assert html =~ "Newer evidence"
      assert html =~ "live-later"
    end
  end
end
