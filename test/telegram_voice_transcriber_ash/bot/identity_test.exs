defmodule TelegramVoiceTranscriberAsh.Bot.IdentityTest do
  use ExUnit.Case, async: true

  alias TelegramVoiceTranscriberAsh.Bot.Identity

  # Pinned against the source bot's
  # hashlib.sha256(str(user_id).encode()).hexdigest(). If these change, every
  # balance migrated from the Django database is orphaned.
  test "the digest matches the source bot bit for bit" do
    assert Identity.hash(123_456_789) ==
             "15e2b0d3c33891ebb0f1ef609ec419420c20e320ce94c65fbc8c3312448eb225"

    assert Identity.hash(1) ==
             "6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b"
  end

  test "the digest is lowercase hex of 64 characters" do
    hash = Identity.hash(42)

    assert String.length(hash) == 64
    assert hash == String.downcase(hash)
    assert Identity.hash(42) == Identity.hash("42")
  end
end
