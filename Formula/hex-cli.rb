# This is a local template. The release workflow generates the real formula
# in your homebrew-tap repo. To use locally:
#   brew install --formula Formula/hex-cli.rb
#
# For tap distribution, create a repo named `homebrew-tap` and add a
# HOMEBREW_TAP_TOKEN secret to this repo. Then users install via:
#   brew tap fbehrens/tap
#   brew install hex-cli

class HexCli < Formula
  desc "On-device audio transcription CLI (WhisperKit + Parakeet)"
  homepage "https://github.com/fbehrens/HexCLI"
  url "https://github.com/fbehrens/HexCLI/releases/download/vVERSION/hex-cli-vVERSION-arm64-apple-macosx.tar.gz"
  sha256 "PLACEHOLDER"
  version "0.1.0"
  license "MIT"

  depends_on :macos
  depends_on macos: :sequoia

  def install
    bin.install "hex-cli"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/hex-cli --version").strip
  end
end
