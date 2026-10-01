cask "squirrel-voice" do
  version "0.1.2"
  sha256 "192a27b3ea6726429d9a1ae7438738d0ee5860544a17f4571b070057f1cf9dbe"

  url "https://github.com/iihciyekub/squirrel-voice/releases/download/v#{version}/SquirrelVoice-#{version}-arm64.zip"
  name "Squirrel Voice"
  desc "Rime input method with lightweight local speech-to-text"
  homepage "https://github.com/iihciyekub/squirrel-voice"

  depends_on macos: :ventura

  input_method "Squirrel Voice.app"

  postflight_steps do
    run "Squirrel Voice.app/Contents/MacOS/Squirrel Voice",
        args: ["--install"],
        base: :appdir
    run "/usr/bin/killall", args: ["TextInputMenuAgent"], must_succeed: false
  end

  uninstall_preflight_steps do
    if_path_exists "Squirrel Voice.app/Contents/MacOS/Squirrel Voice", base: :appdir do
      run "Squirrel Voice.app/Contents/MacOS/Squirrel Voice",
          args:         ["--disable-input-source"],
          base:         :appdir,
          must_succeed: false
    end
    run "/usr/bin/killall", args: ["TextInputMenuAgent"], must_succeed: false
  end

  caveats <<~EOS
    Squirrel Voice is installed for the current user in ~/Library/Input Methods.
    It is registered and enabled automatically after installation.
    Speech models are stored separately and are not downloaded by Homebrew.
  EOS
end
