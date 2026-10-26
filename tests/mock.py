#!/usr/bin/python3
"""Minimal macOS command doubles. State is isolated by MOCK_STATE."""
import json
import os
import pathlib
import sys

name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
path = pathlib.Path(os.environ["MOCK_STATE"])
state = json.loads(path.read_text())


def save():
    path.write_text(json.dumps(state))


if name == "uname":
    print("Darwin")
elif name == "networksetup":
    if args[0] == "-listallnetworkservices":
        print("An asterisk (*) denotes that a network service is disabled.")
        print("\n".join(state["services"]))
    elif args[0] == "-getautoproxyurl":
        item = state["pac"][args[1]]
        print(f"URL: {item['url']}\nEnabled: {item['enabled']}")
    elif args[0] == "-setautoproxyurl":
        state["pac"][args[1]]["url"] = args[2]
        save()
    elif args[0] == "-setautoproxystate":
        if os.getenv("MOCK_FAIL_NETWORK") == "1" and not state.get("network_failed"):
            state["network_failed"] = True
            save()
            sys.exit(1)
        state["pac"][args[1]]["enabled"] = "Yes" if args[2].lower() in ("on", "yes") else "No"
        save()
elif name == "launchctl":
    state["launch"].append(args)
    save()
    if os.getenv("MOCK_FAIL_LAUNCH") == "1" and args[0] == "bootstrap":
        sys.exit(1)
elif name == "nc":
    sys.exit(0 if os.getenv("MOCK_PROXY", "1") == "1" else 1)
elif name == "pgrep":
    if args[:2] == ["-x", "ChatGPT"] and os.getenv("MOCK_MAIN") == "1":
        print("111")
    elif args[:2] == ["-P", "111"] and os.getenv("MOCK_CHILD", "0") == "1":
        print("222")
elif name == "ps":
    if args[:1] == ["-axo"]:
        app = os.getenv("SPLIT_PROXY_APP_PATH", "/Applications/ChatGPT.app")
        with_parent = "ppid=" in args[1]
        if os.getenv("MOCK_MAIN") == "1":
            print(("111 1 " if with_parent else "111 ") + app + "/Contents/MacOS/ChatGPT")
        if os.getenv("MOCK_CHILD") == "1":
            print(("222 111 " if with_parent else "222 ") + app + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        sys.exit(0)
    pid = args[-1]
    app = os.getenv("SPLIT_PROXY_APP_PATH", "/Applications/ChatGPT.app")
    exe = app + ("/Contents/MacOS/ChatGPT" if pid == "111" else "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    if "comm=" in args:
        print(exe)
    else:
        mode = os.getenv("MOCK_ENV", "good")
        url = ("http://127.0.0.1:9999" if mode == "wrong" else
               "" if mode == "empty" else "http://127.0.0.1:7897")
        print(exe + (" --proxy-server=" + url if pid == "111" else "") +
              ((" HTTP_PROXY=" + url + " HTTPS_PROXY=" + url + " ALL_PROXY=" + url)
               if "eww" in args and mode != "unknown" else ""))
elif name == "curl":
    if "split.pac" in " ".join(args):
        pac = pathlib.Path(os.environ["HOME"]) / "proxy-pac/split.pac"
        if pac.exists():
            print(pac.read_text())
        else:
            sys.exit(7)
    elif os.getenv("MOCK_API") == "fail":
        sys.exit(28)
    else:
        print("403", end="")
elif name == "scutil":
    print("ProxyAutoConfigEnable : 1")
    print("ProxyAutoConfigURLString : http://127.0.0.1:8899/split.pac")
elif name == "osascript":
    state["alerts"] = state.get("alerts", 0) + 1
    save()
