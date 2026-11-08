defmodule LightpathWeb.NewsLiveTest do
  use LightpathWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous =
      Map.new(
        [:worker, :fake_worker, :poll_ms, :fixtures_root],
        &{&1, Application.get_env(:lightpath, &1)}
      )

    Application.put_env(:lightpath, :worker, Lightpath.FakeWorker)
    Application.put_env(:lightpath, :fake_worker, %{test: self()})
    Application.put_env(:lightpath, :poll_ms, 5)

    File.ln_s!(
      Path.expand("../../../../fixtures/public/zfs-up-2026-11-08", __DIR__),
      Path.join(tmp, "zfs-up")
    )

    Application.put_env(:lightpath, :fixtures_root, tmp)

    on_exit(fn ->
      Enum.each(previous, fn
        {k, nil} -> Application.delete_env(:lightpath, k)
        {k, v} -> Application.put_env(:lightpath, k, v)
      end)
    end)
  end

  test "no digest yet says so", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/news")
    assert render_async(view) =~ "No digest yet"
  end

  test "shows the latest digest: AI text, items with links and matched packages", %{conn: conn} do
    Application.put_env(:lightpath, :fake_worker, %{
      test: self(),
      news_latest: {:ok, Lightpath.FakeWorker.digest()}
    })

    {:ok, view, _} = live(conn, ~p"/news")
    html = render_async(view)
    assert html =~ "Fake digest: update php."
    assert html =~ "@cf/fake/large"
    assert html =~ "AI can make mistakes"
    assert html =~ "Update to php 8.5.12"
    assert html =~ ~s{href="https://archlinux.org/news/php/"}
    assert html =~ ~s{rel="noopener noreferrer"}

    assert html |> LazyHTML.from_fragment() |> LazyHTML.query(".lp-match") |> LazyHTML.text() =~
             "php"
  end

  test "Update digest uploads the installed packages, starts the Workflow and shows the result",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/news")
    render_async(view)
    view |> element("button", "Update digest") |> render_click()

    assert_receive {:worker, :upload_packages, [visitor, packages]}, 500
    assert visitor =~ ~r/^[0-9a-f]{32}$/
    assert "linux" in packages and "zfs-dkms" in packages
    assert_receive {:worker, :news, [^visitor]}, 500
    assert_receive {:worker, :news_status, [^visitor, "n-1"]}, 500
    Process.sleep(30)
    assert render(view) =~ "Fake digest: update php."
  end

  test "a failure is a notice", %{conn: conn} do
    Application.put_env(:lightpath, :fake_worker, %{
      test: self(),
      news: {:error, "too many AI requests"}
    })

    {:ok, view, _} = live(conn, ~p"/news")
    render_async(view)
    view |> element("button", "Update digest") |> render_click()
    assert_receive {:worker, :news, _}, 500
    Process.sleep(30)
    assert render(view) =~ "too many AI requests"
  end

  test "without the Worker the page says it needs it", %{conn: conn} do
    Application.put_env(:lightpath, :fake_worker, %{available?: false})
    {:ok, _view, html} = live(conn, ~p"/news")
    assert html =~ "LIGHTPATH_WORKER_URL"
    refute html =~ "Update digest"
  end
end
