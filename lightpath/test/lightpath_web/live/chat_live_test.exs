defmodule LightpathWeb.ChatLiveTest do
  use LightpathWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous =
      Map.new([:worker, :fake_worker, :poll_ms], &{&1, Application.get_env(:lightpath, &1)})

    Application.put_env(:lightpath, :worker, Lightpath.FakeWorker)
    Application.put_env(:lightpath, :fake_worker, %{test: self()})
    Application.put_env(:lightpath, :poll_ms, 5)

    on_exit(fn ->
      Enum.each(previous, fn
        {k, nil} -> Application.delete_env(:lightpath, k)
        {k, v} -> Application.put_env(:lightpath, k, v)
      end)
    end)
  end

  defp history(messages),
    do: Application.put_env(:lightpath, :fake_worker, %{test: self(), history: {:ok, messages}})

  test "shows the stored conversation for this visitor", %{conn: conn} do
    history([
      %{"role" => "user", "content" => "Is ZFS up?", "model" => "", "at" => 1},
      %{
        "role" => "assistant",
        "content" => "<b>No</b>, pools are not imported.",
        "model" => "@cf/m",
        "at" => 2
      }
    ])

    {:ok, view, _} = live(conn, ~p"/chat")
    assert_receive {:worker, :history, [visitor, session]}
    assert visitor =~ ~r/^[0-9a-f]{32}$/
    assert session == "chat-" <> visitor

    html = render_async(view)
    assert html =~ "Is ZFS up?"
    assert html =~ "&lt;b&gt;No&lt;/b&gt;, pools are not imported."
    assert html =~ "@cf/m"
    assert html =~ "AI can make mistakes"
  end

  test "asking starts a triage, polls it and shows the answer with why that model answered", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/chat")
    render_async(view)

    after_answer = [
      %{"role" => "user", "content" => "Why is kubelet down?", "model" => "", "at" => 1},
      %{
        "role" => "assistant",
        "content" => "Fake triage answer.",
        "model" => "@cf/fake/large",
        "at" => 2
      }
    ]

    history(after_answer)

    view
    |> form("form.lp-ask", %{"message" => "  Why is kubelet down?  ", "hard" => "true"})
    |> render_submit()

    assert_receive {:worker, :triage, [visitor, "chat-" <> visitor, "Why is kubelet down?", true]}
    assert_receive {:worker, :triage_status, [^visitor, "t-1"]}
    Process.sleep(30)
    html = render(view)
    assert html =~ "Why is kubelet down?"
    assert html =~ "Fake triage answer."
    assert html =~ "the small model suggested a command"
  end

  test "a blank question is ignored", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/chat")
    view |> form("form.lp-ask", %{"message" => "   "}) |> render_submit()
    refute_receive {:worker, :triage, _}, 50
  end

  test "a failed triage is a notice", %{conn: conn} do
    Application.put_env(:lightpath, :fake_worker, %{
      test: self(),
      triage_status: {:ok, %{status: "errored", output: nil, error: "4006: allowance used up"}}
    })

    {:ok, view, _} = live(conn, ~p"/chat")
    view |> form("form.lp-ask", %{"message" => "hi"}) |> render_submit()
    assert_receive {:worker, :triage_status, _}
    Process.sleep(30)
    assert render(view) =~ "4006: allowance used up"
  end

  test "?c= picks the conversation; New conversation links to a fresh one", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/chat?c=abc-123")
    assert_receive {:worker, :history, [_, "abc-123"]}

    [href] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("a.lp-new-chat")
      |> LazyHTML.attribute("href")

    assert href =~ ~r"^/chat\?c=[0-9a-f]{32}$"
    render_async(view)
  end

  test "an invalid ?c= falls back to the visitor's conversation", %{conn: conn} do
    {:ok, _view, _} = live(conn, ~p"/chat?c=../../x")
    assert_receive {:worker, :history, [visitor, session]}
    assert session == "chat-" <> visitor
  end

  test "without the Worker the page says chat needs it", %{conn: conn} do
    Application.put_env(:lightpath, :fake_worker, %{available?: false})
    {:ok, _view, html} = live(conn, ~p"/chat")
    assert html =~ "LIGHTPATH_WORKER_URL"
    refute html =~ "lp-ask"
  end
end
