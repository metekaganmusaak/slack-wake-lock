#!/usr/bin/env python3
"""Verify archives and prebuilt installation without installing into the user account."""
import hashlib
import json
from collections import Counter
import plistlib
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

project = Path(__file__).resolve().parents[1]
version = (project / "VERSION").read_text().strip()
dist = project / "dist"
release_name = f"Slack-Wake-Lock-{version}-macos-universal"
source_name = f"Slack-Wake-Lock-{version}-source"
release_zip = dist / f"{release_name}.zip"
source_zip = dist / f"{source_name}.zip"
language_codes = {"en", "tr", "es", "it", "fr", "de", "ru", "uk", "hi", "zh", "ja", "ko", "pt", "nb", "da", "sv"}
catalog = json.loads((project / "Assets/Localizations.json").read_text())
assert set(catalog) == language_codes
for code, table in catalog.items():
    assert set(table) == set(catalog["en"]), f"Missing translation keys: {code}"
    for key, value in table.items():
        assert value.strip(), f"Empty translation: {code}: {key}"
        assert Counter(re.findall(r"\{\d+\}", key)) == Counter(re.findall(r"\{\d+\}", value)), f"Invalid placeholders: {code}: {key}"
for source in (project / "Sources").glob("*.swift"):
    keys = set(re.findall(r'L10n\.text\("([^"\n]*)"', source.read_text()))
    assert keys <= catalog["en"].keys(), f"Uncatalogued UI strings: {source.name}: {keys - catalog['en'].keys()}"
forbidden_names = {".git", "__MACOSX", ".DS_Store", "config.json", "state.json", "prayer-cache.json", "xcuserdata"}
private_path = b"/" + b"Users" + b"/"
credentials = re.compile(rb"\b(?:xox[baprs]-[A-Za-z0-9-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,})")
email = re.compile(rb"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
# Random machine-code bytes may resemble email addresses. Apply the pattern to
# text files, and check every file for the local Git email.
git_email = subprocess.run(["git", "config", "user.email"], capture_output=True).stdout.strip()

for archive in [release_zip, source_zip]:
    with zipfile.ZipFile(archive) as package:
        assert package.testzip() is None, "Corrupt ZIP data"
        for member in package.infolist():
            path = PurePosixPath(member.filename)
            assert not path.is_absolute() and ".." not in path.parts, "Unsafe archive path"
            assert not forbidden_names.intersection(path.parts), f"Private or cached file: {path}"
            assert not any(part.startswith("._") or part.startswith(".env") for part in path.parts)
            assert path.suffix not in {".log", ".p12", ".p8", ".key", ".mobileprovision", ".provisionprofile"}
            if member.is_dir():
                continue
            data = package.read(member)
            assert private_path not in data, f"Embedded user directory: {path}"
            assert not credentials.search(data), f"Token-like data: {path}"
            textual = path.suffix in {".swift", ".md", ".txt", ".json", ".plist", ".sh", ".py"} or path.name in {"LICENSE", "VERSION", ".gitignore"}
            if textual:
                assert not email.search(data), f"Email-like data: {path}"
            if git_email:
                assert git_email not in data, f"Embedded local Git email: {path}"

with zipfile.ZipFile(source_zip) as source:
    names = set(source.namelist())
    assert f"{source_name}/LICENSE" in names and f"{source_name}/.gitignore" in names
    assert not any("/build/" in name or "/dist/" in name or ".app/" in name for name in names)

with tempfile.TemporaryDirectory(prefix="wakelock-package-check-") as temporary:
    directory = Path(temporary)
    with zipfile.ZipFile(release_zip) as package:
        package.extractall(directory)
    root = directory / release_name
    app = root / "Slack Wake Lock.app"
    executable = app / "Contents/MacOS/Wakelock"
    # zipfile.extractall drops executable modes; check the archived mode separately.
    with zipfile.ZipFile(release_zip) as package:
        entry = package.getinfo(f"{release_name}/Slack Wake Lock.app/Contents/MacOS/Wakelock")
        assert entry.external_attr >> 16 & 0o111, "Missing executable bit"
    executable.chmod(0o755)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleShortVersionString"] == version
    assert info["CFBundleIdentifier"] == "local.wakelock"
    assert info["CFBundleName"] == info["CFBundleDisplayName"] == "Slack Wake Lock"
    assert info["CFBundleDevelopmentRegion"] == "en"
    assert set(info["CFBundleLocalizations"]) == language_codes
    assert json.loads((app / "Contents/Resources/Localizations.json").read_text()) == catalog
    assert (app / "Contents/Resources" / info["CFBundleIconFile"]).is_file()
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    subprocess.run(["lipo", str(executable), "-verify_arch", "arm64", "x86_64"], check=True)
    result = subprocess.run([str(executable), "--version"], check=True, capture_output=True, text=True)
    assert result.stdout.strip() == f"Slack Wake Lock {version}"

    installer = (root / "install.sh").read_text()
    # Run the exact preflight section: app selection and signature verification.
    # This section does not invoke launchctl/pkill/tccutil or modify user files.
    prefix = installer.split("# Stop the previous running version")[0]
    subprocess.run(["bash", "-c", prefix, str(root / "install.sh")], check=True)
    # Verify the production plist code with a path containing special characters.
    fragment = "plutil -create xml1" + installer.split("plutil -create xml1", 1)[1].split('mv "$AGENT_TEMP" "$PLIST"', 1)[0]
    target = str(directory / "User & 'Quote'" / "Applications/Slack Wake Lock.app")
    agent = directory / "test-agent.plist"
    script = 'AGENT_TEMP="$1"\nDEST="$2"\nLABEL="local.wakelock"\n' + fragment
    subprocess.run(["bash", "-eu", "-c", script, "plist-test", str(agent), target], check=True)
    parsed = plistlib.loads(agent.read_bytes())
    assert parsed["ProgramArguments"] == [target + "/Contents/MacOS/Wakelock"]
    assert parsed["RunAtLoad"] and parsed["KeepAlive"] == {"SuccessfulExit": False}

checksums = (dist / f"Slack-Wake-Lock-{version}-SHA256SUMS.txt").read_text().splitlines()
for archive in [release_zip, source_zip]:
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    assert f"{digest}  {archive.name}" in checksums, "SHA-256 mismatch"
print("PASS: ZIP contents, private path/email/token scan, universal architectures, icon, version, signature, prebuilt installation, plist escaping, and SHA-256")
