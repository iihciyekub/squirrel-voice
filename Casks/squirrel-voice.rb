cask "squirrel-voice" do
  version "0.1.2"
  sha256 "192a27b3ea6726429d9a1ae7438738d0ee5860544a17f4571b070057f1cf9dbe"

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
