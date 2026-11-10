"""Keep developer-tool lookup paths out of signed, relocatable Mac binaries."""
import re
import subprocess
import sys


def runpaths(binary):
    commands = subprocess.check_output(["/usr/bin/otool", "-l", binary], text=True)
    return re.findall(r"\bcmd LC_RPATH\n\s*cmdsize \d+\n\s*path (.*?) \(offset \d+\)", commands)


def prepare(binary):
    # The shipped programs use macOS libraries; only the updater embeds a framework.
    # SwiftPM also inserts paths into Xcode and, in debug builds, its own build tree.
    # Remove those from the staged copy before signing it.
    allowed = {"/usr/lib/swift", "@executable_path/../Frameworks"}
    remove = [path for path in dict.fromkeys(runpaths(binary)) if path not in allowed]
    if remove:
        flags = [arg for path in remove for arg in ("-delete_rpath", path)]
        subprocess.run(["/usr/bin/install_name_tool", *flags, binary], check=True)


def verify(binary, *, updater):
    paths = runpaths(binary)
    allowed = {"/usr/lib/swift"}
    if updater:
        frameworks = "@executable_path/../Frameworks"
        if paths.count(frameworks) != 1:
            raise RuntimeError(f"Missing unique embedded framework search path in {binary}")
        allowed.add(frameworks)
    unexpected = set(paths) - allowed
    if unexpected:
        raise RuntimeError(f"Unshippable library search path in {binary}: {unexpected}")


if __name__ == "__main__":
    prepare(sys.argv[1])
