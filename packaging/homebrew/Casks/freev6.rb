cask "freev6" do
  version "0.1.0,9"
  sha256 "640d211c4958b0470f356dfca7a32ae3ffd063c1d95f05a051d3566f0a5bcecd"

  url "https://github.com/study-233/free-v6/releases/download/v#{version.csv.first}/FreeV6-#{version.csv.first}-b#{version.csv.second}-arm64.dmg"
  name "FreeV6"
  desc "IPv6 client for campus networks"
  homepage "https://github.com/study-233/free-v6"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "FreeV6.app"

  caveats <<~EOS
    Before uninstalling, disconnect and remove the network service in FreeV6 settings.
  EOS
end
