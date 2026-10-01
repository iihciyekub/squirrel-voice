cask "squirrel-voice" do
  version "0.1.1"
  sha256 "794651986b00ca574806859bef67ff1db5a6a31b2b6cb2383d1637e4dfeeb0de"

  url "https://github.com/iihciyekub/squirrel-voice/releases/download/v#{version}/SquirrelVoice-#{version}-arm64.zip"
  name "Squirrel Voice"
  desc "Rime input method with lightweight local speech-to-text"
  homepage "https://github.com/iihciyekub/squirrel-voice"

  depends_on macos: :ventura

  input_method "Squirrel Voice.app"

  caveats <<~EOS
    Squirrel Voice is installed for the current user in ~/Library/Input Methods.
    After installation, enable it in System Settings > Keyboard > Input Sources.
    Speech models are stored separately and are not downloaded by Homebrew.
  EOS
end
