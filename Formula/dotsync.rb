# Homebrew Formula for dotsync.
#
# This file is the canonical Formula. To distribute, copy it to a tap repo:
#
#   git clone https://github.com/Voxiven/homebrew-tap
#   cp Formula/dotsync.rb homebrew-tap/Formula/dotsync.rb
#   cd homebrew-tap && git add . && git commit -m "dotsync x.y.z" && git push
#
# Then users install with:
#
#   brew tap voxiven/tap
#   brew install dotsync
#
# When releasing a new version:
#   1. Bump VERSION in bin/dotsync
#   2. Tag and push: git tag vX.Y.Z && git push --tags
#   3. Compute new sha256:
#        curl -sL <tarball-url> | shasum -a 256 | awk '{print $1}'
#   4. Update url + sha256 below
#   5. Push the updated formula to homebrew-tap

class Dotsync < Formula
  desc "Multi-machine continuity for Claude Code and other AI dev tools"
  homepage "https://github.com/Voxiven/dotsync"
  url "https://github.com/Voxiven/dotsync/archive/refs/tags/v0.4.0.tar.gz"
  sha256 "dc17688952e5a75ae51a821c8e93345308b7558a8195add83393adb66f5d1aa9"
  license "MIT"

  depends_on "fswatch"
  depends_on "jq"
  # Linux support is on the roadmap; remove this line once it lands.
  depends_on :macos
  depends_on "magic-wormhole"
  depends_on "syncthing"

  def install
    # Everything goes to libexec (private; not auto-symlinked into PATH).
    # We expose only the top-level dispatcher in bin/.
    libexec.install Dir["*"]

    # The dispatcher resolves symlinks portably, so the symlink in bin/
    # leads back to libexec/bin/dotsync, which finds its sibling
    # dotsync-* scripts (also in libexec/bin) via SCRIPT_DIR.
    bin.install_symlink libexec/"bin/dotsync"
  end

  def caveats
    <<~EOS
      dotsync is installed. To set up multi-machine continuity:

        # First machine
        dotsync init
        dotsync pair

        # Second machine
        dotsync join --code <code from pair>

        # Back on first machine
        dotsync add-peer <id from join's output>

      Diagnostic: dotsync doctor
      Dashboard:  dotsync ui
    EOS
  end

  test do
    assert_match "multi-machine continuity", shell_output("#{bin}/dotsync --help")
    assert_match "dotsync 0.4", shell_output("#{bin}/dotsync version")
    assert_match "claude-code", shell_output("#{bin}/dotsync profiles 2>&1")
  end
end
