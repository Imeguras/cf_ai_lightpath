defmodule Lightpath.Jwt do
  @moduledoc """
  HS256 JSON Web Tokens for calling the Worker, which checks them
  (`worker/src/jwt.ts`). Built on `:crypto`, so there is no dependency.
  """

  @audience "lightpath-worker"
  @lifetime 60

  @doc """
  The compact token for `claims` (a map): base64url without padding of the
  header `{"alg":"HS256","typ":"JWT"}`, of the claims as JSON, and of their
  HMAC-SHA256 signature with `secret`, joined by ".".
  """
  def sign(claims, secret) when is_map(claims) and is_binary(secret) do
    data =
      encode(JSON.encode!(%{"alg" => "HS256", "typ" => "JWT"})) <>
        "." <> encode(JSON.encode!(claims))

    data <> "." <> encode(:crypto.mac(:hmac, :sha256, secret, data))
  end

  @doc """
  A token for one Worker request, issued at `now` (Unix seconds): audience
  "lightpath-worker", `iat` now, `exp` 60 seconds later, `sub` `subject`
  (the Worker rate-limits per subject).
  """
  def for_worker(secret, subject, now \\ System.system_time(:second)) do
    sign(%{"aud" => @audience, "iat" => now, "exp" => now + @lifetime, "sub" => subject}, secret)
  end

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)
end
