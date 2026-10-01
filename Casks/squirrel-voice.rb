cask "squirrel-voice" do
  version "0.1.5"
  sha256 "130bb82940659db2fc67420f1fcd94043f0e2659a3f8a4f42f75ce52e0c58fbd"

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
