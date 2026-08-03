# Homebrew formula. Tap this repo directly:
#   brew tap <user>/ccjuice https://github.com/<user>/ccjuice
#   brew install --HEAD <user>/ccjuice/ccjuice
#
# For stable releases: tag a version (e.g. v1.0.0) — the release workflow prints the
# exact `url` and `sha256` lines in the GitHub release notes; paste them below and
# drop the --HEAD flag.
class Ccjuice < Formula
  desc "MacOS menu bar app showing remaining Claude Code usage percentages"
  homepage "https://github.com/araltiparmak/ccjuice"
  license "MIT"
  head "https://github.com/araltiparmak/ccjuice.git", branch: "main"

  # url "https://github.com/araltiparmak/ccjuice/archive/refs/tags/v1.0.0.tar.gz"
  # sha256 "FILL_ME_IN"

  depends_on :macos

  def install
    system "./build.sh"
    prefix.install "CCJuice.app"
  end

  def caveats
    <<~EOS
      Launch with:
        open #{opt_prefix}/CCJuice.app

      Or copy it to /Applications:
        cp -r #{opt_prefix}/CCJuice.app /Applications/

      On first launch macOS will ask for Keychain access to the Claude Code
      credential — choose "Always Allow".
    EOS
  end

  test do
    assert_predicate prefix/"CCJuice.app/Contents/MacOS/CCJuice", :executable?
  end
end
