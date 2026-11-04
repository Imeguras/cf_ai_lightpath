defmodule LightpathWeb.EvidenceLiveTest do
  # Not async: each test points :fixtures_root at its own directory.
  use LightpathWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.get_env(:lightpath, :fixtures_root)
    Application.put_env(:lightpath, :fixtures_root, tmp)
    on_exit(fn -> Application.put_env(:lightpath, :fixtures_root, previous) end)
    :ok
  end

  defp write_set(root, name, results) do
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
        "created_at" => "2026-11-04T17:32:40Z",
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
    assert LazyHTML.query(doc, ".lp-status--ok") |> Enum.count() >= 2
    assert LazyHTML.query(doc, ".lp-status--failed") |> Enum.count() >= 1
    assert LazyHTML.query(doc, ".lp-status--not-run") |> Enum.count() >= 1
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
end
