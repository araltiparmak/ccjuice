# Homebrew formula. Tap this repo directly:
#   brew tap <user>/ccjuice https://github.com/<user>/ccjuice
#   brew install <user>/ccjuice/ccjuice          # latest release
#   brew install --HEAD <user>/ccjuice/ccjuice   # current main
#
# For a new release: tag a version — the release workflow prints the exact
# `url` and `sha256` lines in the GitHub release notes; update them below.
class Ccjuice < Formula
  desc "MacOS menu bar app showing remaining Claude Code usage percentages"
  homepage "https://github.com/araltiparmak/ccjuice"
  license "MIT"
  head "https://github.com/araltiparmak/ccjuice.git", branch: "main"

  url "https://github.com/araltiparmak/ccjuice/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "712a504e3fec41680339c2022e3ecf83bdd83087301c7c673ecf1b2fdae3e016"

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

      On first launch macOS asks whether CCJuice may read the Claude Code
      credential from your Keychain. Choose "Always Allow" to be asked once.
      The app is signed ad-hoc, and macOS ties that grant to the signature, so
      the question comes back after a `brew upgrade` rebuilds the app.
    EOS
  end

  test do
    assert_predicate prefix/"CCJuice.app/Contents/MacOS/CCJuice", :executable?
  end
end
