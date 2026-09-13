import os, sys, json, time, urllib.request, urllib.error, base64, subprocess

TOK = os.environ["GH_TOKEN"]
REPO = os.environ["GITHUB_REPOSITORY"]
BRANCH = "state"
API = f"https://api.github.com/repos/{REPO}"
H = {"Authorization": f"Bearer {TOK}", "Accept": "application/vnd.github+json"}

def gh(method, path, payload=None, raw=False):
    req = urllib.request.Request(f"{API}/{path}", method=method,
        data=json.dumps(payload).encode() if payload else None, headers=H)
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
        return (data if raw else json.loads(data or b"{}"))

def ensure_state_branch():
    try:
        gh("GET", f"git/ref/heads/{BRANCH}")
        return
    except Exception:
        pass
    main = gh("GET", "git/ref/heads/main")["object"]["sha"]
    c = gh("GET", f"git/commits/{main}")
    nc = gh("POST", "git/commits", {"message": "init state branch", "tree": c["tree"]["sha"], "parents": [main]})
    gh("POST", "git/refs", {"ref": f"refs/heads/{BRANCH}", "sha": nc["sha"]})
    print("[state] created state branch", flush=True)

def push_state():
    ensure_state_branch()
    os.makedirs("/tmp/vps-state", exist_ok=True)
    # Encrypt data directory
    cmd = f"tar -czf - -C data . | openssl enc -aes-256-cbc -pbkdf2 -salt -pass pass:{TOK} -out /tmp/vps-state/state.enc"
    subprocess.run(cmd, shell=True, check=True)
    
    head = gh("GET", f"git/ref/heads/{BRANCH}")["object"]["sha"]
    commit = gh("GET", f"git/commits/{head}")
    base_tree = commit["tree"]["sha"]
    
    items = []
    # 1. state.enc
    with open("/tmp/vps-state/state.enc", "rb") as f:
        enc_data = f.read()
    b_enc = gh("POST", "git/blobs", {"content": base64.b64encode(enc_data).decode(), "encoding": "base64"})
    items.append({"path": "vps-state/state.enc", "mode": "100644", "type": "blob", "sha": b_enc["sha"]})
    
    # 2. boot_receipt.txt
    if os.path.exists("/tmp/vps-state/boot_receipt.txt"):
        with open("/tmp/vps-state/boot_receipt.txt", "rb") as f:
            rcpt_data = f.read()
        b_rcpt = gh("POST", "git/blobs", {"content": base64.b64encode(rcpt_data).decode(), "encoding": "base64"})
        items.append({"path": "vps-state/boot_receipt.txt", "mode": "100644", "type": "blob", "sha": b_rcpt["sha"]})
        
    tree = gh("POST", "git/trees", {"tree": items, "base_tree": base_tree})
    c = gh("POST", "git/commits", {"message": f"state-sync: {time.strftime('%Y-%m-%dT%H:%M:%SZ')}",
                                   "tree": tree["sha"], "parents": [head]})
    gh("PATCH", f"git/refs/heads/{BRANCH}", {"sha": c["sha"], "force": False})
    print(f"[state] pushed state snapshot to branch '{BRANCH}'", flush=True)

def restore_state():
    try:
        d = gh("GET", f"contents/vps-state/state.enc?ref={BRANCH}")
        raw = base64.b64decode(d["content"])
        os.makedirs("/tmp/vps-state", exist_ok=True)
        with open("/tmp/vps-state/state.enc", "wb") as f:
            f.write(raw)
        os.makedirs("data", exist_ok=True)
        cmd = f"openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:{TOK} -in /tmp/vps-state/state.enc | tar -xzf - -C data"
        subprocess.run(cmd, shell=True, check=True)
        print("[state] restored and decrypted state from state branch", flush=True)
        return True
    except Exception as e:
        print(f"[state] no existing state to restore ({e})", flush=True)
        return False

if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else "push-once"
    if cmd == "restore":
        success = restore_state()
        sys.exit(0 if success else 1)
    elif cmd == "push-once":
        push_state()
    elif cmd == "push-loop":
        while True:
            time.sleep(120)
            try:
                push_state()
            except Exception as e:
                print(f"[state] push loop error: {e}", flush=True)