cask "squirrel-voice" do
  version "0.1.4"
  sha256 "06689a45eb3b16294c01185d9ee122123644dad5240100b000b36d68a2da805b"

  url "https://github.com/iihciyekub/squirrel-voice/releases/download/v#{version}/SquirrelVoice-#{version}-arm64.zip"
  name "Squirrel Voice"
  desc "Rime input method with lightweight local speech-to-text"
  homepage "https://github.com/iihciyekub/squirrel-voice"

  depends_on macos: :ventura

  input_method "Squirrel Voice.app"

  caveats <<~EOS
    Squirrel Voice is installed for the current user in ~/Library/Input Methods.
    Add Squirrel Voice once in System Settings > Keyboard > Text Input > Edit.
    Speech models are stored separately and are not downloaded by Homebrew.
  EOS
end
