"""Label fork releases by the official commits they actually contain."""
import argparse
import json
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
OFFICIAL = "https://github.com/komari-monitor/komari-agent"
FORK = "luosx0403/komari-agent"


def git(*args, repo=ROOT):
    return subprocess.check_output(["git", *args], cwd=repo, text=True).strip()


def gh(*args):
    # gh can otherwise choose the upstream remote by default in a fork checkout.
    return subprocess.check_output(["gh", *args, "--repo", FORK], cwd=ROOT, text=True)


def metadata(source, repo=ROOT):
    source = git("rev-parse", "--verify", source + "^{commit}", repo=repo)
    commit = git("merge-base", source, "refs/remotes/upstream/main", repo=repo)
    tags = git("for-each-ref", "--format=%(refname:strip=3)", "refs/tags/upstream", repo=repo).splitlines()
    stable = []
    for tag in tags:
        match = re.fullmatch(r"[vV]?(\d+)\.(\d+)\.(\d+)", tag)
        if match:
            stable.append((tuple(map(int, match.groups())), tag))
    version = "unreleased"
    for _, tag in sorted(stable, reverse=True):
        result = subprocess.run(["git", "merge-base", "--is-ancestor", f"refs/tags/upstream/{tag}", source], cwd=repo)
        if result.returncode == 0:
            version = tag
            break
        if result.returncode != 1:
            raise RuntimeError("cannot inspect official tag ancestry")
    return {"upstream_version": version, "upstream_commit": commit}


def release_notes(body, values):
    # Replace the old fixed baseline and our generated fields, preserving all
    # other release notes. Repeated checks must not append duplicate lines.
    lines = [line for line in (body or "").splitlines() if not line.startswith(("Upstream baseline:", "Included official version:", "Upstream source:"))]
    version, commit = values["upstream_version"], values["upstream_commit"]
    version_link = f"[{version}]({OFFICIAL}/releases/tag/{version})" if version != "unreleased" else version
    return "\n".join(lines).rstrip() + f"\nIncluded official version: {version_link}.\nUpstream source: [{commit}]({OFFICIAL}/commit/{commit}).\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", default="HEAD")
    parser.add_argument("--refresh-latest", action="store_true")
    args = parser.parse_args()
    subprocess.run(["git", "fetch", "--no-tags", OFFICIAL+".git", "+refs/heads/main:refs/remotes/upstream/main", "+refs/tags/*:refs/tags/upstream/*"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    if not args.refresh_latest:
        for key, value in metadata(args.source).items():
            print(f"{key}={value}")
        return
    release = json.loads(gh("release", "view", "--json", "tagName,targetCommitish,body,name"))
    source = release["targetCommitish"]
    if not re.fullmatch(r"[0-9a-f]{40,64}", source):
        source = git("rev-parse", "--verify", release["tagName"]+"^{commit}")
    values = metadata(source)
    name = f"Lifetime Traffic {release['tagName']} (upstream {values['upstream_version']})"
    notes = release_notes(release["body"], values)
    if name == release["name"] and notes == release["body"]:
        print(f"{release['tagName']}: upstream {values['upstream_version']} already labelled; no build needed.")
        return
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as body:
        body.write(notes)
        body.flush()
        gh("release", "edit", release["tagName"], "--title", name, "--notes-file", body.name)
    print(f"{release['tagName']}: labelled upstream {values['upstream_version']} ({values['upstream_commit']}); binaries unchanged.")


if __name__ == "__main__":
    main()
