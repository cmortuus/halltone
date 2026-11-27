#!/bin/bash
# CI test for server/setup.sh. Run as root in a clean Debian 12 container (no systemd):
#   setup twice (idempotent: same key, token, config), then exercise nginx, the log receiver,
#   the published installer and its signature, and the release importer against fake releases.
set -euo pipefail
export LC_ALL=C.UTF-8
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SETUP="$HERE/../server/setup.sh"
FAKE=/tmp/fake-releases
ok()   { printf 'ok   - %s\n' "$*"; }
fail() { printf 'FAIL - %s\n' "$*" >&2; exit 1; }
gpgh() { runuser -u repo -- env GNUPGHOME=/var/lib/repo/.gnupg gpg "$@"; }

snapshot() {
  {
    gpgh --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}'
    sha256sum /etc/halltone-logrx/token /srv/apt/halltone/conf/distributions /srv/apt/halltone/conf/options \
      /srv/apt/halltone/halltone-archive-keyring.gpg /srv/apt/install-halltone.sh /srv/apt/install-halltone.desktop \
      /etc/nginx/sites-available/apt /etc/systemd/system/halltone-*.service /etc/systemd/system/halltone-*.timer \
      /usr/local/bin/halltone-*
    ls -l /etc/nginx/sites-enabled
  }
}

echo "### setup.sh, first run"
"$SETUP"
snapshot > /tmp/snap1
echo "### setup.sh, second run (existing server)"
"$SETUP"
snapshot > /tmp/snap2
diff -u /tmp/snap1 /tmp/snap2 && ok "second run changed nothing (key, token, config, units, published installer)"

echo "### start nginx and the log receiver (no systemd here)"
nginx
runuser -u halltonelog -- /usr/local/bin/halltone-logrx > /tmp/logrx.out 2>&1 &
for _ in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:8082/ && break; sleep 0.2; done

base=http://127.0.0.1
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

[ "$(code $base/halltone/dists/stable/InRelease)" = 200 ] && ok "InRelease served"
[ "$(code $base/halltone/conf/distributions)" = 403 ] && ok "reprepro conf is denied"
[ "$(code $base/halltone/db/version)" = 403 ] && ok "reprepro db is denied"
grep -q '^Architectures: amd64 arm64 i386 armhf$' /srv/apt/halltone/dists/stable/Release && ok "Release lists the pinned architectures"

token=$(cat /etc/halltone-logrx/token)
[ -n "$token" ] || fail "empty token"
[ "$(stat -c %a:%U:%G /etc/halltone-logrx/token)" = "640:root:halltonelog" ] && ok "token file is root:halltonelog 640"

echo "### published installer"
curl -fsS $base/install-halltone.sh -o /tmp/pub.sh
curl -fsS $base/install-halltone.sh.asc -o /tmp/pub.sh.asc
curl -fsS $base/install-halltone.desktop -o /tmp/pub.desktop
curl -fsS $base/halltone/halltone-archive-keyring.gpg -o /tmp/keyring.gpg
grep -q "^LOG_TOKEN=\"$token\"\$" /tmp/pub.sh && ok "token substituted at publish time"
if grep -q '__LOG_TOKEN__' /tmp/pub.sh; then fail "placeholder left in published installer"; fi
if grep -rq "$token" "$HERE/../.." ; then fail "token found in the git checkout"; fi
gpgv --keyring /tmp/keyring.gpg /tmp/pub.sh.asc /tmp/pub.sh 2>/dev/null && ok "installer signature verifies against the served keyring"
echo '# tampered' >> /tmp/pub.sh
if gpgv --keyring /tmp/keyring.gpg /tmp/pub.sh.asc /tmp/pub.sh 2>/dev/null; then fail "tampered installer verified"; fi
ok "tampered installer fails verification"
grep -q '^Exec=sh -c .*install-halltone.sh' /tmp/pub.desktop && ok "launcher published"
[ "$(stat -c %a /srv/apt/install-halltone.sh)" = 755 ] && ok "published installer is executable"

echo "### log receiver"
post() { curl -s -o /dev/null -w '%{http_code}' -H "X-Halltone-Log-Token: $1" -H 'X-Halltone-Host: ci-box' --data-binary "$2" "$base/halltone-logs/$3"; }
[ "$(post "$token" hello install)" = 204 ] && ok "upload with token accepted"
[ "$(post wrong hello install)" = 403 ] && ok "wrong token rejected"
[ "$(post "$token" hello 'Bad/Kind')" = 404 ] && ok "bad kind rejected"
grep -q hello /var/log/halltone-clients/ci-box/install-*.log && ok "upload stored per host"
big=$(head -c 6000000 /dev/zero | curl -s -o /dev/null -w '%{http_code}' -H "X-Halltone-Log-Token: $token" --data-binary @- "$base/halltone-logs/install" || true)
if [ "$big" = 413 ]; then ok "over 5 MB rejected"; else fail "over-limit upload got '$big'"; fi

echo "### release importer"
rm -rf "$FAKE"; mkdir -p "$FAKE/pkg/DEBIAN" "$FAKE/pkg/usr/bin" "$FAKE/web"
printf 'Package: halltone-linux\nVersion: 1.2.3\nArchitecture: amd64\nMaintainer: ci <ci@example.invalid>\nDescription: stub for importer test\n' > "$FAKE/pkg/DEBIAN/control"
printf '#!/bin/sh\necho stub\n' > "$FAKE/pkg/usr/bin/halltone-linux"; chmod 755 "$FAKE/pkg/usr/bin/halltone-linux"
dpkg-deb --build "$FAKE/pkg" "$FAKE/web/halltone-linux_1.2.3_amd64.deb" >/dev/null
cp "$FAKE/web/halltone-linux_1.2.3_amd64.deb" "$FAKE/web/halltone-linux_9.9.9_amd64.deb"
(cd "$FAKE/web" && sha256sum halltone-linux_1.2.3_amd64.deb > SHA256SUMS)
mkdir "$FAKE/bad"; cp "$FAKE/web/halltone-linux_9.9.9_amd64.deb" "$FAKE/bad/"
echo "0000000000000000000000000000000000000000000000000000000000000000  halltone-linux_9.9.9_amd64.deb" > "$FAKE/bad/SHA256SUMS"
chmod -R a+rX "$FAKE"
(cd "$FAKE" && python3 -m http.server 8090 --bind 127.0.0.1 > /tmp/http.out 2>&1 &) ; sleep 1
U=http://127.0.0.1:8090
jq -n --arg u "$U" '[
  {tag_name:"linux-v9.9.9", draft:false, assets:[{name:"halltone-linux_9.9.9_amd64.deb", browser_download_url:($u+"/bad/halltone-linux_9.9.9_amd64.deb")},{name:"SHA256SUMS", browser_download_url:($u+"/bad/SHA256SUMS")}]},
  {tag_name:"linux-v1.2.3", draft:false, assets:[{name:"halltone-linux_1.2.3_amd64.deb", browser_download_url:($u+"/web/halltone-linux_1.2.3_amd64.deb")},{name:"SHA256SUMS", browser_download_url:($u+"/web/SHA256SUMS")}]},
  {tag_name:"v0.1", draft:false, assets:[]}
]' > "$FAKE/releases.json"; chmod a+r "$FAKE/releases.json"
sync_run() { runuser -u repo -- env HALLTONE_RELEASES_API="$U/releases.json" /usr/local/bin/halltone-repo-sync; }
if sync_run > /tmp/sync1.out 2>&1; then fail "importer accepted a release with a bad checksum"; fi
cat /tmp/sync1.out
grep -q 'linux-v1.2.3: imported' /tmp/sync1.out && ok "good release imported"
[ -e /var/lib/repo/state/linux-v1.2.3.done ] && [ ! -e /var/lib/repo/state/linux-v9.9.9.done ] && ok "bad-checksum release refused"
runuser -u repo -- env GNUPGHOME=/var/lib/repo/.gnupg reprepro -b /srv/apt/halltone list stable | tee /tmp/list.out
grep -q 'halltone-linux 1.2.3' /tmp/list.out && ! grep -q 9.9.9 /tmp/list.out && ok "repo has only the verified .deb"
curl -fsS $base/halltone/dists/stable/main/binary-amd64/Packages | grep -q '^Version: 1.2.3' && ok "Packages index served"
n=$(sync_run 2>&1 | grep -c 'imported' || true)
if [ "$n" = 0 ]; then ok "re-running the importer imports nothing twice"; else fail "importer re-imported ($n)"; fi
echo "ALL SERVER TESTS PASSED"
