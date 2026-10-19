#!/usr/bin/env python3
"""Arşivleri ve hazır kurulum yolunu kullanıcı hesabına kurulum yapmadan doğrular."""
import hashlib
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
forbidden_names = {".git", "__MACOSX", ".DS_Store", "config.json", "state.json", "prayer-cache.json", "xcuserdata"}
private_path = b"/" + b"Users" + b"/"
credentials = re.compile(rb"\b(?:xox[baprs]-[A-Za-z0-9-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,})")
email = re.compile(rb"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
# Makine kodundaki rastgele baytlar e-posta biçimine benzeyebilir. Metin
# dosyalarında genel desen; tüm dosyalarda yerel Git e-postası denetlenir.
git_email = subprocess.run(["git", "config", "user.email"], capture_output=True).stdout.strip()

for archive in [release_zip, source_zip]:
    with zipfile.ZipFile(archive) as package:
        assert package.testzip() is None, "ZIP verisi bozuk"
        for member in package.infolist():
            path = PurePosixPath(member.filename)
            assert not path.is_absolute() and ".." not in path.parts, "Güvensiz arşiv yolu"
            assert not forbidden_names.intersection(path.parts), f"Özel/önbellek dosyası: {path}"
            assert not any(part.startswith("._") or part.startswith(".env") for part in path.parts)
            assert path.suffix not in {".log", ".p12", ".p8", ".key", ".mobileprovision", ".provisionprofile"}
            if member.is_dir():
                continue
            data = package.read(member)
            assert private_path not in data, f"Kullanıcı dizini gömülmüş: {path}"
            assert not credentials.search(data), f"Token benzeri veri: {path}"
            textual = path.suffix in {".swift", ".md", ".txt", ".json", ".plist", ".sh", ".py"} or path.name in {"LICENSE", "VERSION", ".gitignore"}
            if textual:
                assert not email.search(data), f"E-posta benzeri veri: {path}"
            if git_email:
                assert git_email not in data, f"Yerel Git e-postası gömülmüş: {path}"

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
    # zipfile.extractall Unix çalıştırma bitini korumaz; arşivin bitini ayrıca denetle.
    with zipfile.ZipFile(release_zip) as package:
        entry = package.getinfo(f"{release_name}/Slack Wake Lock.app/Contents/MacOS/Wakelock")
        assert entry.external_attr >> 16 & 0o111, "Çalıştırma biti eksik"
    executable.chmod(0o755)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleShortVersionString"] == version
    assert info["CFBundleIdentifier"] == "local.wakelock"
    assert info["CFBundleName"] == info["CFBundleDisplayName"] == "Slack Wake Lock"
    assert (app / "Contents/Resources" / info["CFBundleIconFile"]).is_file()
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    subprocess.run(["lipo", str(executable), "-verify_arch", "arm64", "x86_64"], check=True)
    result = subprocess.run([str(executable), "--version"], check=True, capture_output=True, text=True)
    assert result.stdout.strip() == f"Slack Wake Lock {version}"

    installer = (root / "install.sh").read_text()
    # Ön doğrulama bölümünü aynen çalıştır: paket seçimi ve imza kontrolü.
    # launchctl/pkill/tccutil veya gerçek kullanıcının dosyaları bu bölümde kullanılmaz.
    prefix = installer.split("# Çalışan eski sürümü durdur")[0]
    subprocess.run(["bash", "-c", prefix, str(root / "install.sh")], check=True)
    # Üretimde kullanılan plist kodunu özel karakterli bir yol ile doğrula.
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
    assert f"{digest}  {archive.name}" in checksums, "SHA-256 eşleşmiyor"
print("PASS: ZIP içerikleri, kişisel yol/e-posta/token taraması, universal mimari, ikon, sürüm, imza, hazır kurulum, plist kaçışları ve SHA-256")
