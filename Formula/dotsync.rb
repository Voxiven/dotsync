# Homebrew Formula for dotsync.
#
# This file is the canonical Formula. To distribute, copy it to a tap repo:
#
#   git clone https://github.com/Voxiven/homebrew-tap
#   cp Formula/dotsync.rb homebrew-tap/Formula/dotsync.rb
#   cd homebrew-tap && git add . && git commit -m "dotsync 0.4.0" && git push
#
# Then users install with:
#
#   brew tap voxiven/tap
#   brew install dotsync
#
# When releasing a new version:
#   1. Bump VERSION in bin/dotsync
#   2. Tag and push: git tag v0.4.x && git push --tags
#   3. Update url + sha256 below (sha256 = sha256sum of the GitHub tarball)
#   4. Push the updated formula to homebrew-tap

class Dotsync < Formula
  desc "Multi-machine continuity for Claude Code and other AI dev tools"
  homepage "https://github.com/Voxiven/dotsync"
  url "https://github.com/Voxiven/dotsync/archive/refs/tags/v0.4.0.tar.gz"
  # sha256 — fill in after pushing the tag with:
  #   curl -sL <url> | shasum -a 256 | awk '{print $1}'
  sha256 "REPLACE_WITH_TARBALL_SHA256"
  license "MIT"
  version "0.4.0"

  depends_on :macos    # Linux support is on the roadmap; remove this line once it lands
  depends_on "syncthing"
  depends_on "jq"
  depends_on "fswatch"
  depends_on "magic-wormhole"

  def install
    # Stage everything under the formula's prefix.
    prefix.install Dir["bin", "profiles", "launchd", "docs", "examples",
                       "README.md", "LICENSE"]

    # Symlink the dispatcher into Homebrew's bin/. The dispatcher resolves
    # symlinks itself so it locates its sibling dotsync-* scripts in the
    # cellar correctly.
    bin.install_symlink prefix/"bin/dotsync"
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
    # Smoke checks: --help and --version exit 0 without touching anything.
    assert_match "multi-machine continuity", shell_output("#{bin}/dotsync --help")
    assert_match "dotsync 0.4", shell_output("#{bin}/dotsync version")

    # Profile JSONs are well-formed and the loader doesn't crash.
    assert_match "claude-code", shell_output("#{bin}/dotsync profiles 2>&1", 0)
  end
end
