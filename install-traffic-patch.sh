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
KEYS = ("AGENT_NETWORK_MODE", "AGENT_NETWORK_STATE_FILE", "AGENT_NETWORK_SAVE_INTERVAL", "AGENT_UPDATE_REPO", "AGENT_NETWORK_SYNC_ON_REPORT")


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
        if is_openwrt() and not info.get("network_sync_on_report_option"):
            raise RuntimeError("iStoreOS requires a newer release with configurable report checkpointing")
    return expected, release["tag_name"]


PROCD_BEGIN = "# BEGIN KOMARI LIFETIME TRAFFIC PATCH"
PROCD_END = "# END KOMARI LIFETIME TRAFFIC PATCH"


def is_openwrt():
    return pathlib.Path("/etc/openwrt_release").is_file() and pathlib.Path("/sbin/procd").exists()


def clean_procd_script(text):
    return re.sub(r"(?m)^\s*"+re.escape(PROCD_BEGIN)+r"\n.*?^\s*"+re.escape(PROCD_END)+r"\n?", "", text, flags=re.S)


def procd_script(text, settings):
    text = clean_procd_script(text)
    if not settings:
        return text
    pattern = r"(?m)^([ \t]*)procd_close_instance[ \t]*$"
    if len(re.findall(pattern, text)) != 1:
        raise RuntimeError("this adapter requires one standard procd instance")
    for value in settings.values():
        if any(c in value for c in "\n\r\x00"):
            raise ValueError("multiline procd environment values are not supported")
    block = PROCD_BEGIN+"\n    procd_append_param env "+" ".join(shlex.quote(k+"="+v) for k,v in settings.items())+"\n    "+PROCD_END+"\n"
    return re.sub(pattern, lambda m: m[1]+block+m[0], text)


def procd_instances(service):
    result = run(["ubus", "call", "service", "list", json.dumps({"name":service})])
    return list(json.loads(result.stdout).get(service, {}).get("instances", {}).values())


def openwrt_plan(args):
    if args.scope == "user":
        raise RuntimeError("the iStoreOS adapter uses a system procd service")
    service = args.service.removesuffix(".service")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", service):
        raise ValueError("invalid procd service name")
    config = pathlib.Path("/etc/init.d")/service
    text = config.read_text()
    if not re.search(r"(?m)^USE_PROCD=1\s*$", text):
        raise RuntimeError("existing service is not a standard procd script")
    instances = procd_instances(service)
    if len(instances) > 1:
        raise RuntimeError("multiple procd instances need a separate adapter")
    instance = instances[0] if instances else {}
    if instance.get("user", "root") != "root":
        raise RuntimeError("this iStoreOS adapter expects the existing root Komari service")
    command = instance.get("command", [])
    if command:
        executable = command[0]
    else:
        match = re.search(r"(?m)^PROG=(.+)$", text)
        values = shlex.split(match[1]) if match else []
        if len(values) != 1 or not values[0].startswith("/"):
            raise RuntimeError("cannot identify inactive procd executable from a static PROG assignment")
        executable = values[0]
    binary = pathlib.Path(args.binary or executable).resolve()
    if binary != pathlib.Path(executable).resolve():
        raise RuntimeError("--binary must match the existing procd executable")
    state = pathlib.Path(args.state_file or "/etc/komari-agent-lifetime/network-total.json").resolve()
    for location in (binary, state):
        if not location.is_absolute() or any(location == root or root in location.parents for root in (pathlib.Path("/tmp"),pathlib.Path("/run"),pathlib.Path("/dev"))):
            raise RuntimeError("iStoreOS binary and state must be on persistent storage, not /tmp or volatile /var")
    procd_script(text, {"AGENT_NETWORK_MODE":"lifetime"})  # Validate before any stop or write.
    return dict(kind="procd", scope="system", service=service, binary=str(binary), config=str(config), uid=0, gid=0, state_file=str(state), active=bool(instance.get("running")))


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
    if plan["kind"] == "procd":
        if action == "reload":
            return None
        return run([plan["config"], action], check)
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
        if plan["kind"] == "procd":
            ok = any(i.get("running") for i in procd_instances(plan["service"]))
        elif plan["kind"] == "systemd":
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
        atomic_copy(backup/"config", config, 0o755 if plan["kind"] == "procd" else None)
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
        if not data["official"]:
            settings["AGENT_NETWORK_SYNC_ON_REPORT"] = str(data.get("sync_on_report", True)).lower()
        if data["disable_auto_update"] is not None and not data["official"]:
            settings["AGENT_DISABLE_AUTO_UPDATE"] = str(data["disable_auto_update"]).lower()
        if plan["kind"] == "procd":
            staged = pathlib.Path(manifest).parent/"procd-init"
            staged.write_text(procd_script(config.read_text(), settings))
            atomic_copy(staged, config, 0o755)
        elif plan["kind"] == "systemd":
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


class DesktopUnavailable(RuntimeError):
    """Retain prepared files for execution at the physical desktop."""


class AuthenticationPending(RuntimeError):
    """Keep staged files while a desktop worker might still be running."""


def properties(text):
    return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


def session_scope(pid):
    try:
        return pathlib.Path(f"/proc/{pid}/cgroup").read_text()
    except OSError:
        return ""


def linux_desktop():
    """Read actual login sessions, bus ownership and agent placement; no elevation."""
    uid = os.getuid()
    sessions = run(["loginctl", "list-sessions", "--no-legend"], False)
    environment = properties(run(["systemctl", "--user", "show-environment"], False).stdout)
    env = os.environ.copy()
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"):
        env.pop(name, None)
        if environment.get(name):
            env[name] = environment[name]
    runtime = pathlib.Path(environment.get("XDG_RUNTIME_DIR", f"/run/user/{uid}"))
    if not runtime.is_dir() or runtime.stat().st_uid != uid or not (runtime/"bus").is_socket():
        raise RuntimeError("No accessible graphical session D-Bus for this user")
    env["XDG_RUNTIME_DIR"] = str(runtime)
    env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path="+str(runtime/"bus")
    bus = subprocess.run(["busctl", "--user", "list", "--no-pager", "--no-legend"], env=env, text=True, capture_output=True)
    owners = [line.split() for line in bus.stdout.splitlines() if line.startswith("org.Cinnamon ")]
    processes = run(["ps", "-eo", "pid=,comm="], False).stdout.splitlines()
    for row in sessions.stdout.splitlines():
        session = row.split()[0]
        info = properties(run(["loginctl", "show-session", session, "-p", "User", "-p", "Active", "-p", "Remote", "-p", "Type", "-p", "Scope", "-p", "Display"], False).stdout)
        scope = info.get("Scope", "")
        if info.get("User") != str(uid) or info.get("Active") != "yes" or info.get("Remote") != "no" or info.get("Type") not in ("x11", "wayland") or not re.fullmatch(r"session-[A-Za-z0-9_.-]+\.scope", scope):
            continue
        if info.get("Display"):
            env["DISPLAY"] = info["Display"]
        if info["Type"] == "x11":
            match = re.fullmatch(r":(\d+)(?:\.\d+)?", env.get("DISPLAY", ""))
            if not match or not pathlib.Path("/tmp/.X11-unix", "X"+match[1]).is_socket():
                continue
        agents = []
        for process in processes:
            parts = process.split(None, 1)
            if len(parts) == 2 and any(s in parts[1] for s in ("polkit-gnome", "polkit-kde", "polkit-mate", "lxpolkit", "polkit-agent", "gnome-shell")) and scope in session_scope(parts[0]):
                agents.append(parts[0])
        cinnamon = bool(owners and len(owners[0]) > 1 and scope in session_scope(owners[0][1]))
        agent = None
        if not agents and cinnamon:
            agent = next((p for p in ("/usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1", "/usr/libexec/polkit-gnome-authentication-agent-1") if os.access(p, os.X_OK)), None)
        if not agents and not agent:
            continue
        if cinnamon:
            return dict(kind="cinnamon", scope=scope, env=env, agent=agent)
        if scope in session_scope(os.getpid()):
            return dict(kind="direct", scope=scope, env=env, agent=None)
    raise RuntimeError("No verified desktop authentication route: SSH currently supports an active same-user Cinnamon session; other desktops need a local graphical terminal")


def mac_desktop():
    uid = os.stat("/dev/console").st_uid
    if uid == 0 or uid != os.getuid():
        raise RuntimeError("No active macOS console desktop belonging to the SSH user")
    run(["launchctl", "print", f"gui/{uid}"])
    return dict(kind="launchd-auth", domain=f"gui/{uid}")


def auth_worker(manifest, agent=None):
    """Runs inside the verified GUI session; no password handling or retry."""
    stage = pathlib.Path(manifest).parent
    command = [sys.executable, str(stage/"installer.py"), "--apply", str(manifest)]
    process = None
    with (stage/"authorization.log").open("w") as log:
        try:
            if platform.system() == "Linux":
                if agent:
                    process = subprocess.Popen([agent], stdout=log, stderr=log)
                    time.sleep(1)
                    # An existing registered agent may make this one exit. Do not
                    # start another; pkexec must use the session's registered agent.
                result = subprocess.run(["pkexec", "--disable-internal-agent"]+command, stdout=log, stderr=log)
            else:
                expression = "do shell script "+json.dumps(shlex.join(command))+" with administrator privileges"
                result = subprocess.run(["osascript", "-e", expression], stdout=log, stderr=log)
            code = result.returncode
        except Exception as error:
            print(str(error), file=log)
            code = 1
        finally:
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    temporary = stage/"authorization-result.tmp"
    temporary.write_text(str(code))
    os.replace(temporary, stage/"authorization-result")


def wait_desktop_result(stage, name, timeout):
    target = stage/name
    deadline = time.monotonic()+timeout
    while not target.exists():
        if time.monotonic() >= deadline:
            raise AuthenticationPending(f"Desktop operation is still pending; staged files retained at {stage}. Do not retry while its authentication window is open")
        time.sleep(0.1)
    return target.read_text()


def cinnamon_spawn(route, wrapper):
    # Eval contains only one generated absolute wrapper path, never a command,
    # manifest content, service arguments, passwords or caller-supplied text.
    expression = "imports.misc.util.spawnCommandLine("+json.dumps(shlex.quote(str(wrapper)))+")"
    result = subprocess.run(["gdbus", "call", "--session", "--dest", "org.Cinnamon", "--object-path", "/org/Cinnamon", "--method", "org.Cinnamon.Eval", expression], env=route["env"], text=True, capture_output=True)
    if result.returncode or not re.match(r"\(true,", result.stdout.strip()):
        raise RuntimeError("Cinnamon rejected the desktop launch; no authentication retry was attempted")


def authorize(command, stage, method):
    if method == "sudo-n":
        # Explicit opt-in only: sudo -n cannot read or prompt for a password.
        result = subprocess.run(["sudo", "-n", "--"]+command)
        if result.returncode:
            raise RuntimeError("Configured noninteractive sudo authorization or installation failed; no password fallback")
        return
    if method == "none":
        raise RuntimeError("System installation needs an authorized root session or graphical authentication")
    try:
        route = linux_desktop() if platform.system() == "Linux" else mac_desktop()
    except RuntimeError as error:
        local = ["pkexec", "--disable-internal-agent"]+command if platform.system() == "Linux" else ["osascript", "-e", "do shell script "+json.dumps(shlex.join(command))+" with administrator privileges"]
        raise DesktopUnavailable(str(error)+". Prepared files retained; run at the target machine's local desktop: "+shlex.join(local)) from error
    if route["kind"] == "direct":
        print("An administrator window will appear on the target machine's physical desktop. Enter the password only in that graphical window.", flush=True)
        result = subprocess.run(["pkexec", "--disable-internal-agent"]+command, env=route["env"])
        if result.returncode:
            raise RuntimeError("Graphical authentication or installation failed; no retry or terminal password fallback")
        return
    script, manifest = str(stage/"installer.py"), str(stage/"manifest.json")
    worker = [sys.executable, script, "--auth-worker", manifest]
    if route.get("agent"):
        worker += ["--session-agent", route["agent"]]
    label = None
    if route["kind"] == "cinnamon":
        # Validate the session scope with an unprivileged probe before any prompt.
        probe = stage/"session-probe.sh"
        probe.write_text("#!/bin/sh\ncat /proc/self/cgroup > "+shlex.quote(str(stage/"session-scope"))+"\n")
        probe.chmod(0o700)
        cinnamon_spawn(route, probe)
        if route["scope"] not in wait_desktop_result(stage, "session-scope", 10):
            raise RuntimeError("Desktop probe did not enter the expected graphical session; authentication was not started")
        wrapper = stage/"authorize.sh"
        wrapper.write_text("#!/bin/sh\nexec "+shlex.join(worker)+"\n")
        wrapper.chmod(0o700)
    print("An administrator authentication window will appear on the TARGET MACHINE'S PHYSICAL DESKTOP (not in SSH). Enter the password only in that graphical window.", flush=True)
    if route["kind"] == "cinnamon":
        cinnamon_spawn(route, wrapper)
    else:
        label = "com.komari.traffic-auth."+uuid.uuid4().hex
        plist = stage/"authorize.plist"
        plist.write_bytes(plistlib.dumps(dict(Label=label, ProgramArguments=worker, RunAtLoad=True, StandardOutPath=str(stage/"worker.log"), StandardErrorPath=str(stage/"worker.log"))))
        run(["launchctl", "bootstrap", route["domain"], str(plist)])
    try:
        code = int(wait_desktop_result(stage, "authorization-result", 600))
    except AuthenticationPending:
        # The GUI worker can still finish. Do not boot it out or remove its files.
        raise
    else:
        if label:
            run(["launchctl", "bootout", route["domain"]+"/"+label], False)
    log = stage/"authorization.log"
    if log.exists():
        print(log.read_text(), end="")
    if code:
        raise RuntimeError(f"Desktop authentication cancelled or installation failed (exit {code}); no retry or password fallback")


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
    parser.add_argument("--save-interval", type=float, default=None, help="checkpoint seconds; default 300 on iStoreOS, 5 elsewhere")
    parser.add_argument("--network-sync-on-report", choices=["true", "false"], default=None, help="default false on iStoreOS to reduce flash writes, true elsewhere")
    parser.add_argument("--disable-auto-update", dest="disable_auto_update", action="store_const", const=True, default=None)
    parser.add_argument("--enable-auto-update", dest="disable_auto_update", action="store_const", const=False)
    parser.add_argument("--no-restart", action="store_true")
    parser.add_argument("--dry-run", action="store_true", help="show detected target without downloads or changes")
    parser.add_argument("--download-only", metavar="DIRECTORY")
    parser.add_argument("--auth", choices=["auto", "desktop", "sudo-n", "none"], default="auto", help="SSH: target desktop authentication, or explicit configured noninteractive sudo")
    parser.add_argument("--auth-check", action="store_true", help="read-only detection of desktop authentication route")
    parser.add_argument("--auth-worker", help=argparse.SUPPRESS)
    parser.add_argument("--session-agent", help=argparse.SUPPRESS)
    parser.add_argument("--apply", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.auth_worker:
        auth_worker(args.auth_worker, args.session_agent)
        return
    if args.auth_check:
        route = linux_desktop() if platform.system() == "Linux" else mac_desktop()
        print(json.dumps({key:value for key,value in route.items() if key != "env"}, indent=2))
        return
    if args.apply:
        apply(args.apply)
        return
    openwrt = platform.system() == "Linux" and is_openwrt()
    if args.save_interval is None:
        args.save_interval = 300 if openwrt else 5
    sync_on_report = args.network_sync_on_report != "false" if args.network_sync_on_report is not None else not openwrt
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
    if openwrt:
        plan = openwrt_plan(args)
    elif platform.system() == "Linux":
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
        data = dict(plan=plan, action="install", mode=args.mode, official=args.official, repo=repo, save_interval=args.save_interval, disable_auto_update=args.disable_auto_update, no_restart=args.no_restart, sync_on_report=sync_on_report)
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
            try:
                authorize(command, stage, args.auth)
            except (DesktopUnavailable, AuthenticationPending, KeyboardInterrupt):
                keep_stage = True
                raise
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
