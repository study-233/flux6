cask "flux6" do
  version "0.1.1,12"
  sha256 "238d6b3411b34f9b006da083ba37e1a8f8e714cb796ab1854f5c7e1a4ceff934"

  url "https://github.com/study-233/flux6/releases/download/v#{version.csv.first}/Flux6-#{version.csv.first}-macos-arm64.dmg"
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
