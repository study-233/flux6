cask "flux6" do
  version "0.1.2,13"
  sha256 "dc6febd340b12b6c01ab8d7ea5592fae80eec5bce89164bdbc01143ce54b5e35"

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
