defmodule Lightpath.JwtTest do
  use ExUnit.Case, async: true

  alias Lightpath.Jwt

  # Computed independently with Python's hmac/hashlib/base64.
  @vector "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJsaWdodHBhdGgtd29ya2VyIiwiZXhwIjoxODAwMDAwMDYwLCJpYXQiOjE4MDAwMDAwMDAsInN1YiI6IndlYiJ9.m0Mtq__uuPBVQSVVtE-ieulE12M9SjF1lp5I_PG5xw0"

  test "sign/2 matches an independent HS256 implementation" do
    claims = %{
      "aud" => "lightpath-worker",
      "exp" => 1_800_000_060,
      "iat" => 1_800_000_000,
      "sub" => "web"
    }

    assert Jwt.sign(claims, "test-secret") == @vector
  end

  test "for_worker/3 has the audience, a 60 second lifetime and the subject" do
    token = Jwt.for_worker("s3cret", "visitor-7", 1_800_000_000)
    [header, payload, signature] = String.split(token, ".")

    assert Base.url_decode64!(header, padding: false) |> JSON.decode!() ==
             %{"alg" => "HS256", "typ" => "JWT"}

    assert Base.url_decode64!(payload, padding: false) |> JSON.decode!() == %{
             "aud" => "lightpath-worker",
             "iat" => 1_800_000_000,
             "exp" => 1_800_000_060,
             "sub" => "visitor-7"
           }

    expected = :crypto.mac(:hmac, :sha256, "s3cret", header <> "." <> payload)
    assert Base.url_decode64!(signature, padding: false) == expected
    refute token =~ "="
  end

  test "for_worker/2 uses the current time" do
    [_, payload, _] = String.split(Jwt.for_worker("s", "web"), ".")
    claims = Base.url_decode64!(payload, padding: false) |> JSON.decode!()
    assert abs(claims["iat"] - System.system_time(:second)) <= 2
  end
end
