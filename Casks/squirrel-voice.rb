cask "squirrel-voice" do
  version "0.1.3"
  sha256 "0fd218d814e7e5233f6029ec59d419ff110e5dcf5addcac7d9ad2b77442f8204"

  url "https://github.com/iihciyekub/squirrel-voice/releases/download/v#{version}/SquirrelVoice-#{version}-arm64.zip"
  name "Squirrel Voice"
  desc "Rime input method with lightweight local speech-to-text"
  homepage "https://github.com/iihciyekub/squirrel-voice"

  depends_on macos: :ventura

  input_method "Squirrel Voice.app"

  caveats <<~EOS
    Squirrel Voice is installed for the current user in ~/Library/Input Methods.
    After the first install, open Squirrel Voice once so macOS can register the input method:
      open "$HOME/Library/Input Methods/Squirrel Voice.app"
    Speech models are stored separately and are not downloaded by Homebrew.
  EOS
end
