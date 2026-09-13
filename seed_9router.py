import urllib.request, json, time, hmac, hashlib, base64, os, subprocess

URL = "http://127.0.0.1:20128"
JWT = "p387oefxdgqcqbzl"

def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
now = int(time.time())
h = b64u(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
p = b64u(json.dumps({"authenticated": True, "iat": now, "exp": now + 86400}).encode())
sig = b64u(hmac.new(JWT.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest())
jwt = f"{h}.{p}.{sig}"

TOK = os.environ["GH_TOKEN"]
cmd = f"openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:{TOK} -in seed_state.enc"
r = subprocess.run(cmd, shell=True, capture_output=True, text=True, check=True)
db_data = json.loads(r.stdout)
db_data["password"] = "6755"

req = urllib.request.Request(f"{URL}/api/settings/database",
    headers={
        "Cookie": f"auth_token={jwt}",
        "x-9r-cli-token": "1",
        "x-9r-password": "6755",
        "Content-Type": "application/json"
    },
    data=json.dumps(db_data).encode(),
    method="POST"
)

for attempt in range(10):
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print("DB Import success:", resp.status, resp.read().decode()[:150])
            break
    except Exception as e:
        print(f"Seed attempt {attempt+1} err: {e}")
        time.sleep(3)