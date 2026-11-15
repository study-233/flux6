cask "flux6" do
  version "0.1.1,11"
  sha256 "a539cde2480b462bcb59301537bf88234bc5f17f13ed0e7efdafff3d88fc6c7e"

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
