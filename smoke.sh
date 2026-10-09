#!/usr/bin/env bash
# BoostContent v1 definition of done: the customer journey over HTTP, as the app does it.
#   ./smoke.sh                         → through the local entry (caddy :3100, Host boostcontent.io)
#   BASE=https://boostcontent.io ./smoke.sh   → through Cloudflare
# Exit 0 = PASS. Needs curl + python3 (stdlib). Takes ~2–4 min (real LLM + image renders).
set -uo pipefail
cd "$(dirname "$0")"
BASE=${BASE:-http://127.0.0.1:3100}
HOSTH=(); [[ $BASE == http://127.0.0.1* ]] && HOSTH=(-H "Host: boostcontent.io")
PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
j()   { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1" 2>/dev/null; }
local_url() { [[ $BASE == http://127.0.0.1* ]] && echo "$1" | sed "s#https://boostcontent.io#$BASE#" || echo "$1"; }
api() { curl -s "${HOSTH[@]}" "$BASE/rest/v1/$1" -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' "${@:2}"; }

echo "== $BASE"
signup() { curl -s "${HOSTH[@]}" "$BASE/auth/v1/signup" -H 'content-type: application/json' -d '{}' | j 'd["access_token"]'; }
TOKEN=$(signup)
[ -n "$TOKEN" ] && ok "guest sign-in (GoTrue anonymous)" || { bad "guest sign-in"; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' "${HOSTH[@]}" "$BASE/rest/v1/posts")" = 401 ] && ok "no token → 401" || bad "API open without a token"

ME=$(api rpc/me -X POST -d '{}')
[ "$(echo "$ME" | j 'd["limits"]["images_month"]')" -gt 0 ] && ok "account + quota ($(echo "$ME" | j 'd["limits"]'))" || bad "me: $ME"

BIZ=$(api rpc/create_business -d '{"name":"Smoke Bakery","description":"Homemade cakes and pastries in Kyiv, pickup and delivery.","language":"uk"}' | j 'd["id"]')
[ -n "$BIZ" ] && ok "business created" || { bad "create_business"; exit 1; }

UP=$(api rpc/upload_url -d "{\"business_id\":\"$BIZ\",\"content_type\":\"image/jpeg\"}")
PUT=$(local_url "$(echo "$UP" | j 'd["put_url"]')"); MID=$(echo "$UP" | j 'd["media_id"]')
C=$(curl -s -o /dev/null -w '%{http_code}' "${HOSTH[@]}" -X PUT --data-binary @scripts/fixtures/product.jpg "$PUT")
[ "$C" = 200 ] && ok "photo PUT straight to storage with the pre-signed URL" || bad "photo PUT: HTTP $C"
api rpc/photo_uploaded -d "{\"media_id\":\"$MID\"}" >/dev/null
GETU=$(local_url "$(api "photos?business_id=eq.$BIZ" | j 'd[0]["url"]')")
[ "$(curl -s "${HOSTH[@]}" "$GETU" | head -c 3 | od -An -tx1 | tr -d ' ')" = ffd8ff ] && ok "photo readable via pre-signed GET" || bad "photo GET"

T0=$(date +%s)
POST=$(api rpc/generate_posts -d "{\"business_id\":\"$BIZ\",\"n\":1}" | j 'd[0]["id"]')
[ -n "$POST" ] && ok "generate_posts queued" || { bad "generate_posts"; exit 1; }
for i in $(seq 120); do
  ST=$(api "posts?id=eq.$POST" | j 'd[0]["status"]')
  [[ $ST == ready || $ST == partial || $ST == failed ]] && break; sleep 5
done
P=$(api "posts?id=eq.$POST")
NIMG=$(echo "$P" | j 'sum(1 for i in d[0]["images"] if i["status"]=="ready")')
[ "$ST" = ready ] && [ "${NIMG:-0}" -ge 1 ] && ok "post ready in $(( $(date +%s) - T0 )) s: $NIMG image(s), caption: $(echo "$P" | j 'd[0]["caption"][:70]')…" \
  || bad "post status $ST after $(( $(date +%s) - T0 )) s: $(echo "$P" | head -c 400)"
IMG=$(local_url "$(echo "$P" | j '[i for i in d[0]["images"] if i["url"]][0]["url"]')")
[ "$(curl -s "${HOSTH[@]}" "$IMG" | head -c 4 | od -An -tx1 | tr -d ' ')" = 89504e47 ] && ok "generated image downloadable (PNG)" || bad "generated image GET"
[ "$(echo "$P" | j 'd[0]["language"]')" = uk ] && [ "$(echo "$P" | j 'sum(1 for c in d[0]["caption"] if "\u0400" <= c <= "\u04ff") > 10')" = True ] \
  && ok "caption is Ukrainian (Cyrillic)" || bad "caption language"

PROF=$(api "profiles?business_id=eq.$BIZ" | j 'd[0]["status"]')
[ "$PROF" = ready ] && ok "style profile learned from the photo" || bad "profile: $PROF"

USED=$(api rpc/me -X POST -d '{}' | j 'd["used"]["posts"]')
[ "$USED" = 1 ] && ok "quota counted (posts used: 1)" || bad "quota used: $USED"

api rpc/post_signal -d "{\"post_id\":\"$POST\",\"kind\":\"copied\"}" >/dev/null
E=$(api rpc/edit_post -d "{\"post_id\":\"$POST\",\"caption\":\"Мій власний текст\"}" | j 'd["caption"]')
[ "$E" = "Мій власний текст" ] && ok "caption edit saved (training signal)" || bad "edit_post"

OTHER=$(signup)
[ "$(curl -s "${HOSTH[@]}" "$BASE/rest/v1/posts?id=eq.$POST" -H "Authorization: Bearer $OTHER" | j 'len(d)')" = 0 ] && ok "another guest cannot see the post" || bad "isolation"

if docker ps --format '{{.Names}}' | grep -q '^bc-db$'; then
  TR=$(docker exec bc-db psql -U postgres -d boostcontent -tAc "select string_agg(distinct step, ',' order by step) from private.gen_trace where business_id = '$BIZ'")       # ideas is traced per batch, so match by business
  SG=$(docker exec bc-db psql -U postgres -d boostcontent -tAc "select string_agg(kind, ',' order by kind) from private.signals where post_id = '$POST'")
  [[ $TR == *ideas* && $TR == *image* && $TR == *profile* ]] && ok "gen_trace rows: $TR" || bad "gen_trace: $TR"
  [ "$SG" = "copied,edited" ] && ok "signals: $SG" || bad "signals: $SG"
fi
api rpc/delete_business -d "{\"id\":\"$BIZ\"}" >/dev/null
# leave no test users behind (the admin's user list is the owner's view of real customers)
if docker ps --format '{{.Names}}' | grep -q '^bc-db$'; then
  ids=$(for t in "$TOKEN" "$OTHER"; do python3 -c "import sys,json,base64; p=sys.argv[1].split('.')[1]; print(json.loads(base64.urlsafe_b64decode(p+'='*(-len(p)%4)))['sub'])" "$t"; done | sed "s/.*/'&'/" | paste -sd,)
  docker exec bc-db psql -U postgres -d boostcontent -qc "delete from private.accounts where id in ($ids); delete from auth.users where id in ($ids);" \
    && echo "  (test users removed)"
fi

echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
