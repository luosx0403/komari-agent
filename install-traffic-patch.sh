#!/bin/sh
""":"
command -v python3 >/dev/null 2>&1 || { echo 'Python 3.9+ is required.' >&2; exit 1; }
exec python3 "$0" "$@"
":"""
"""Install release binaries over an existing Linux/macOS Komari service."""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

DEFAULT_REPO = "luosx0403/komari-agent"
OFFICIAL_REPO = "komari-monitor/komari-agent"
KEYS = ("AGENT_NETWORK_MODE", "AGENT_NETWORK_STATE_FILE", "AGENT_NETWORK_SAVE_INTERVAL", "AGENT_UPDATE_REPO")


def run(args, check=True):
    result = subprocess.run(args, text=True, capture_output=True)
    if check and result.returncode:
        # Service definitions and command arguments can contain credentials.
        raise RuntimeError(f"{args[0]} failed (exit {result.returncode}); inspect the service locally")
    return result


def sha256(path):
    with open(path, "rb") as stream:
        return hashlib.sha256(stream.read()).hexdigest()


def valid_repo(repo):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("repository must be owner/name")
    return repo


def api_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "komari-traffic-patch", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.load(response)


def download_release(repo, version, destination, enhanced):
    valid_repo(repo)
    suffix = "latest" if version == "latest" else "tags/" + urllib.parse.quote(version, safe="")
    release = api_json(f"https://api.github.com/repos/{repo}/releases/{suffix}")
    machine = {"x86_64": "amd64", "AMD64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine())
    system = {"Linux": "linux", "Darwin": "darwin"}.get(platform.system())
    if not machine or not system:
        raise RuntimeError("supported platforms: Linux/macOS, amd64/arm64")
    name = f"komari-agent-{system}-{machine}"
    asset = next((a for a in release["assets"] if a["name"] == name), None)
    if not asset:
        raise RuntimeError(f"release {release['tag_name']} has no {name}")
    digest = asset.get("digest", "")
    if not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
        raise RuntimeError("release asset has no verifiable GitHub SHA-256 digest")
    request = urllib.request.Request(asset["browser_download_url"], headers={"User-Agent": "komari-traffic-patch"})
    with urllib.request.urlopen(request, timeout=120) as response, open(destination, "wb") as output:
        shutil.copyfileobj(response, output)
    expected = digest.split(":", 1)[1].lower()
    if sha256(destination) != expected:
        raise RuntimeError("download checksum mismatch")
    os.chmod(destination, 0o755)
    if enhanced:
        info = json.loads(run([str(destination), "build-info"]).stdout)
        if not info.get("lifetime_network") or info.get("network_state_version") != 1:
            raise RuntimeError("binary does not support lifetime traffic state v1")
    return expected, release["tag_name"]


def linux_plan(args):
    unit = args.service.removesuffix(".service") + ".service"
    if not re.fullmatch(r"[A-Za-z0-9_.@-]+\.service", unit):
        raise ValueError("invalid service name")
    for scope in (["user", "system"] if args.scope == "auto" else [args.scope]):
        ctl = ["systemctl"] + (["--user"] if scope == "user" else [])
        fragment = run(ctl + ["show", unit, "--property=FragmentPath", "--value"], False)
        if fragment.returncode or not fragment.stdout.strip():
            continue
        command = run(ctl + ["show", unit, "--property=ExecStart", "--value"]).stdout
        match = re.search(r"\bpath=(.*?)\s*;\s*argv\[\]=", command)
        if not match:
            raise RuntimeError("cannot identify the service executable; use a standard systemd ExecStart")
        binary = pathlib.Path(args.binary or match.group(1).strip()).resolve()
        if str(binary) != str(pathlib.Path(match.group(1).strip()).resolve()):
            raise RuntimeError("--binary must match the existing service executable")
        user = run(ctl + ["show", unit, "--property=User", "--value"]).stdout.strip()
        owner = pwd.getpwnam(user) if user else pwd.getpwuid(os.getuid() if scope == "user" else 0)
        base = pathlib.Path(owner.pw_dir) / ".local/state/komari-agent" if scope == "user" else pathlib.Path("/var/lib/komari-agent-lifetime")
        config = pathlib.Path(owner.pw_dir) / ".config/systemd/user" / (unit + ".d/90-traffic-patch.conf") if scope == "user" else pathlib.Path("/etc/systemd/system") / (unit + ".d/90-traffic-patch.conf")
        active = run(ctl + ["is-active", "--quiet", unit], False).returncode == 0
        return dict(kind="systemd", scope=scope, service=unit, binary=str(binary), config=str(config), uid=owner.pw_uid, gid=owner.pw_gid, state_file=str(pathlib.Path(args.state_file).absolute() if args.state_file else base / "network-total.json"), active=active)
    raise RuntimeError("existing Komari service not found; specify --scope and --service")


def mac_plan(args):
    service = args.service.removesuffix(".service")
    candidates = [pathlib.Path(args.plist)] if args.plist else [pathlib.Path.home()/"Library/LaunchAgents"/f"com.komari.{service}.plist", pathlib.Path("/Library/LaunchDaemons")/f"com.komari.{service}.plist"]
    for path in candidates:
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            data = plistlib.load(stream)
        scope = "system" if str(path).startswith("/Library/LaunchDaemons/") else "user"
        if args.scope != "auto" and args.scope != scope:
            continue
        executable = data.get("Program") or data.get("ProgramArguments", [None])[0]
        if not executable:
            raise RuntimeError("launchd executable not found")
        binary = pathlib.Path(args.binary or executable).resolve()
        if binary != pathlib.Path(executable).resolve():
            raise RuntimeError("--binary must match the launchd executable")
        owner = pwd.getpwnam(data["UserName"]) if data.get("UserName") else pwd.getpwuid(0 if scope == "system" else os.getuid())
        base = pathlib.Path("/Library/Application Support/Komari") if scope == "system" else pathlib.Path(owner.pw_dir)/"Library/Application Support/Komari"
        domain = "system" if scope == "system" else f"gui/{os.getuid()}"
        active = run(["launchctl", "print", domain+"/"+data["Label"]], False).returncode == 0
        return dict(kind="launchd", scope=scope, service=data["Label"], domain=domain, binary=str(binary), config=str(path.resolve()), uid=owner.pw_uid, gid=owner.pw_gid, state_file=str(pathlib.Path(args.state_file).absolute() if args.state_file else base/"network-total.json"), active=active)
    raise RuntimeError("existing Komari launchd plist not found; specify --plist")


def atomic_copy(source, target, mode=None):
    target = pathlib.Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name("."+target.name+".patch-"+uuid.uuid4().hex)
    try:
        shutil.copy2(source, temporary)
        if target.exists():
            old = target.stat()
            if os.geteuid() == 0:
                os.chown(temporary, old.st_uid, old.st_gid)
        if mode is not None:
            os.chmod(temporary, mode)
        with temporary.open("rb") as stream:
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def service_control(plan, action, check=True):
    if plan["kind"] == "systemd":
        ctl = ["systemctl"] + (["--user"] if plan["scope"] == "user" else [])
        return run(ctl + (["daemon-reload"] if action == "reload" else [action, plan["service"]]), check)
    if action == "reload":
        return None
    if action == "stop":
        return run(["launchctl", "bootout", plan["domain"], plan["config"]], check)
    return run(["launchctl", "bootstrap", plan["domain"], plan["config"]], check)


def verify_service(plan):
    for _ in range(10):
        if plan["kind"] == "systemd":
            ctl = ["systemctl"] + (["--user"] if plan["scope"] == "user" else [])
            ok = run(ctl+["is-active", "--quiet", plan["service"]], False).returncode == 0
        else:
            result = run(["launchctl", "print", plan["domain"]+"/"+plan["service"]], False)
            ok = result.returncode == 0 and "state = running" in result.stdout
        if ok:
            return
        time.sleep(0.5)
    raise RuntimeError("service did not become active; restoring previous binary and settings")


def restore(plan, backup):
    atomic_copy(backup/"agent", plan["binary"], 0o755)
    config = pathlib.Path(plan["config"])
    if (backup/"config").exists():
        atomic_copy(backup/"config", config)
    else:
        config.unlink(missing_ok=True)
    service_control(plan, "reload")


def apply(manifest):
    data = json.loads(pathlib.Path(manifest).read_text())
    plan = data["plan"]
    binary, config = pathlib.Path(plan["binary"]), pathlib.Path(plan["config"])
    if data["action"] == "rollback":
        pointer = pathlib.Path(plan["binary"]).parent/".traffic-patch-backups/latest.json"
        previous = json.loads(pointer.read_text())
        active = plan["active"]
        plan = previous["plan"]
        plan["active"] = active
        backup = pathlib.Path(previous["backup"])
        if plan["active"] and not data["no_restart"]:
            service_control(plan, "stop")
        restore(plan, backup)
        if plan["active"] and not data["no_restart"]:
            service_control(plan, "start")
            verify_service(plan)
        print("Previous binary and service settings restored; lifetime state retained.")
        return
    if sha256(data["artifact"]) != data["sha256"]:
        raise RuntimeError("staged binary checksum mismatch")
    if sha256(binary) != data["original_sha256"]:
        raise RuntimeError("installed binary changed during preparation; run the installer again")
    backup = binary.parent/".traffic-patch-backups"/(time.strftime("%Y%m%d-%H%M%S")+"-"+uuid.uuid4().hex[:8])
    backup.mkdir(parents=True, mode=0o700)
    os.chmod(backup.parent, 0o700)
    shutil.copy2(binary, backup/"agent")
    if config.exists():
        shutil.copy2(config, backup/"config")
        os.chmod(backup/"config", 0o600)
    (backup/"plan.json").write_text(json.dumps(plan))
    stopped = False
    try:
        if plan["active"] and not data["no_restart"]:
            service_control(plan, "stop")
            stopped = True
        if not data["official"]:
            state_dir = pathlib.Path(plan["state_file"]).parent
            if not state_dir.exists():
                state_dir.mkdir(parents=True, mode=0o700)
                if os.geteuid() == 0:
                    os.chown(state_dir, plan["uid"], plan["gid"])
        atomic_copy(data["artifact"], binary, 0o755)
        settings = {} if data["official"] else dict(zip(KEYS, [data["mode"], plan["state_file"], str(data["save_interval"]), data["repo"]]))
        if data["disable_auto_update"] is not None and not data["official"]:
            settings["AGENT_DISABLE_AUTO_UPDATE"] = str(data["disable_auto_update"]).lower()
        if plan["kind"] == "systemd":
            if data["official"]:
                config.unlink(missing_ok=True)
            else:
                # systemd specifiers (%) and quotes must be escaped, not shell-quoted.
                def escape(value):
                    return value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
                text = "[Service]\n"+"".join('Environment="'+escape(k+"="+v)+'"\n' for k,v in settings.items())
                staged = pathlib.Path(manifest).parent/"service-drop-in"
                staged.write_text(text)
                atomic_copy(staged, config, 0o644)
        else:
            with config.open("rb") as stream:
                plist = plistlib.load(stream)
            env = plist.setdefault("EnvironmentVariables", {})
            for key in KEYS:
                env.pop(key, None)
            env.update(settings)
            staged = pathlib.Path(manifest).parent/"service.plist"
            staged.write_bytes(plistlib.dumps(plist))
            atomic_copy(staged, config)
        service_control(plan, "reload")
        if stopped:
            service_control(plan, "start")
            verify_service(plan)
        pointer = backup.parent/"latest.json"
        pointer.write_text(json.dumps({"backup":str(backup), "plan":plan}))
        os.chmod(pointer, 0o600)
    except Exception:
        if stopped:
            service_control(plan, "stop", False)
        restore(plan, backup)
        if stopped:
            service_control(plan, "start", False)
        raise
    print(f"Installed {data['version']} ({'official binary' if data['official'] else data['mode']+' totals'}).")
    print(f"Backup: {backup}")
    if not data["official"]:
        print(f"Lifetime state: {plan['state_file']}")
        print("Automatic updates keep their existing setting; default is enabled.")
    if data["no_restart"]:
        print("Service restart deferred; restart it manually to activate this binary.")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Patch an existing Linux/macOS Komari Agent using verified release binaries")
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--version", default="latest")
    parser.add_argument("--mode", choices=["lifetime", "official"], default="lifetime")
    parser.add_argument("--official", action="store_true", help="install actual official binary and remove patch settings")
    parser.add_argument("--rollback", action="store_true", help="restore previous binary/settings; keep lifetime state")
    parser.add_argument("--scope", choices=["auto", "user", "system"], default="auto")
    parser.add_argument("--service", default="komari-agent")
    parser.add_argument("--plist", help="existing macOS launchd plist")
    parser.add_argument("--binary", help="must match the existing service executable")
    parser.add_argument("--state-file")
    parser.add_argument("--save-interval", type=float, default=5)
    parser.add_argument("--disable-auto-update", dest="disable_auto_update", action="store_const", const=True, default=None)
    parser.add_argument("--enable-auto-update", dest="disable_auto_update", action="store_const", const=False)
    parser.add_argument("--no-restart", action="store_true")
    parser.add_argument("--dry-run", action="store_true", help="show detected target without downloads or changes")
    parser.add_argument("--download-only", metavar="DIRECTORY")
    parser.add_argument("--apply", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.apply:
        apply(args.apply)
        return
    if not 0.1 <= args.save_interval <= 3600:
        parser.error("save interval must be between 0.1 and 3600 seconds")
    repo = OFFICIAL_REPO if args.official else valid_repo(args.repo)
    if args.download_only:
        directory = pathlib.Path(args.download_only).absolute()
        directory.mkdir(parents=True, exist_ok=True)
        digest, version = download_release(repo, args.version, directory/"agent", not args.official)
        (directory/"SHA256SUMS").write_text(digest+"  agent\n")
        print(f"Downloaded and verified {version}: {directory/'agent'}")
        return
    if platform.system() == "Linux":
        plan = linux_plan(args)
    elif platform.system() == "Darwin":
        plan = mac_plan(args)
    else:
        parser.error("only Linux and macOS are supported")
    if args.dry_run:
        print(json.dumps(plan, indent=2))
        return
    stage = pathlib.Path(tempfile.mkdtemp(prefix="komari-traffic-patch-"))
    keep_stage = False
    try:
        data = dict(plan=plan, action="install", mode=args.mode, official=args.official, repo=repo, save_interval=args.save_interval, disable_auto_update=args.disable_auto_update, no_restart=args.no_restart)
        if args.rollback:
            # System backups are private; read the rollback pointer only after elevation.
            data.update(action="rollback")
        else:
            artifact = stage/"agent"
            digest, version = download_release(repo, args.version, artifact, not args.official)
            data.update(artifact=str(artifact), sha256=digest, version=version, original_sha256=sha256(plan["binary"]))
        manifest = stage/"manifest.json"
        manifest.write_text(json.dumps(data))
        script = stage/"installer.py"
        shutil.copy2(__file__, script)
        command = [sys.executable, str(script), "--apply", str(manifest)]
        if plan["scope"] == "system" and os.geteuid() != 0:
            if platform.system() == "Linux":
                if os.environ.get("SSH_CONNECTION") or not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
                    keep_stage = True
                    raise RuntimeError("Cannot verify graphical authentication from this session. Run at the target machine's local desktop: "+shlex.join(["pkexec", "--disable-internal-agent"]+command))
                print("An administrator authentication window will appear on this desktop. Enter your password only in that graphical window.", flush=True)
                result = subprocess.run(["pkexec", "--disable-internal-agent"]+command)
            else:
                print("A macOS administrator authentication window will appear. Enter your password only in that graphical window.", flush=True)
                apple_command = "do shell script "+json.dumps(shlex.join(command))+" with administrator privileges"
                result = subprocess.run(["osascript", "-e", apple_command])
            if result.returncode:
                raise RuntimeError(f"graphical authorization or installation failed (exit {result.returncode}); no terminal password fallback")
        else:
            apply(manifest)
    finally:
        if not keep_stage:
            shutil.rmtree(stage)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Error: "+str(error), file=sys.stderr)
        sys.exit(1)
