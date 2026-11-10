cask "flux6" do
  version "0.1.0,10"
  sha256 "e60c6cabf100b7058d0f57b8a53df5646177c69b8056ec5518cff4750c7b4fda"

  url "https://github.com/study-233/flux6/releases/download/v#{version.csv.first}/Flux6-#{version.csv.first}-macOS.dmg"
  name "Flux6"
  desc "IPv6 client for campus networks"
  homepage "https://study-233.github.io/flux6/"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Flux6.app"

  caveats <<~EOS
    Before uninstalling, disconnect and remove the network service in Flux6 settings.
  EOS
end
