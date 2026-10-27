#!/bin/zsh
# Publish guard: fails if anything that would go into the public repo is HoMedics material (app, firmware,
# stock patterns) or third-party internals. Runs as a pre-commit hook and in CI.
# Usage: scripts/check-publishable.sh            (checks git-tracked + staged files, or all files outside git)
set -uo pipefail
cd "$(dirname "$0")/.."
SELF=scripts/check-publishable.sh

# SHA-256 of known HoMedics files (the official APK, its firmware images, its stock patterns).
# Fingerprints only; none of that content is in this repo.
KNOWN=(
  04760a4ffe0bb083796904a0465e705449f59f0714dfa3763d6150070d4d3271
  15ae19c125a2da37b22dff91b179921945ebfa788f384daa1234736b336860f7
  2e08e988ba66dc7b9e22c2558520d793a2f3d6a5676b2498e1b2569ece784e62
  2f5dbcf1fc3fb1bf8a3e497bd228e9aec37482bb9ab722bb484ffafe73bede4c
  3e15e3762844435c97530ff7dd45c90c92ec52a253479599b4e0cecc2c4f3b7d
  432545363379d7dc3241b7d7a23b743d5793a13fe15123e9d893081dc38f685a
  438aa104698ed48ffd43c7b57dbd4b228b46261c4935101fdf5321d11bef2f65
  5f514e98ab0106c7ef9864cba172e453a425e1defed30a74ef8e16ccde49ccb3
  6105c77cc23938db29bf2ff9f50a0789859f07626160d86b325d299c108ff215
  7a9d6c14686bb31ae410a5ac8b5d72d7703f3dc43af116d72ec31a48fa658e19
  83eeaa283f7433cdfe811c27fc34c3a738cddb4391bd021bc54cd7e7a16801df
  8da5394bd9e57e69ec5b9afab08e22a5c3a168e2865ef98480cc7d9fe19b45b4
  8ffa9fc7eed4483f25b6a8f737b2aef5e394dde2c170fe7ae5dadc44c7ee5d96
  a5f28fa8e28d6605a337fc7fe63eaf4bb240d6887a0d99e268445b2c50f51aba
  aa1031a54e4f9ce4f64fb9047e2bf7bf3a15ec466b3b3979b8633be085c9511a
  b8cd85b83b081d2998d9e2c921e611a16b37590f2cb3ac226b6f4ef54360d76a
  b9bba9075eb9cda529ae625e3136e2329dccd6e56b5a613b3bf3daa585f1fcb7
  c4903afe7a12ac1373e6767769db41c2932d73d6d92e1b1178d7fd2527119db1
  ca31e303ce0e82102700b73136de8f5284aef8fdfb77299bf24689f984fd0eb5
  cba0981e02dd1ce6204fad7627deae18a42838468346a00aa39c08fa83ea10e0
  d3081e9042228f5a9e462ef6bd2f9ce280b0a9c047044f30d1a679e3b8324412
  e64617490fbe2344444978a0d5f9e4a6afb48ee8e7e8ce4d6356c85e19b9bed3
  f2ac5b90fe95212e9fb28ce0a90daa40d85bce2508df09d2bcbd81311f3fe331
)

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  FILES=("${(@f)$( { git ls-files; git diff --cached --name-only --diff-filter=AM; } | sort -u)}")
else
  FILES=("${(@f)$(find . -type f -not -path './.build/*' -not -path './build/*' -not -path './.git/*' | sed 's|^\./||' | sort)}")
fi

fail=0
problem() { print -u2 "✘ $1"; fail=1; }

# Tooling words that don't belong in this repo. Case-insensitive extended regexes.
PATTERNS=( 'jadx' 'smali' 'apktool' 'decompil' 'disassembl' 'capstone' 'ghidra' 'reverse.engineer' )
# More patterns from a local, unpublished file: git config drifted.privatePatterns /path/to/patterns.txt
PRIVATE=$(git config --get drifted.privatePatterns 2>/dev/null)
if [[ -n "$PRIVATE" && -f "$PRIVATE" ]]; then
  PATTERNS+=("${(@f)$(grep -v -e '^#' -e '^$' "$PRIVATE")}")
fi

# Third-party identifiers, as truncated SHA-256 of lowercased words and dotted/slashed word pairs, so this
# file doesn't name them.
BLOCKED_WORDS=(
  012f000de3e6520d 040f3d21c2676048 0caaa081a5491402 1c7c3f829367d54a 2ee2611e31149ab6 4394443b5a630e73
  448ad913c09c708b 52217abaf99a1abc 63b3deaed6a2c4f5 6771886131a27fbc 76592e43f9c2a158 7c2768e68501bc1e
  9bf810e538989782 9d5bc22e620a8efd be5a602eccfb1402 bf19ff29de583cc7 d7bcafacc114ada3 da3fc570a44c6376
  e58ddd387d9ecdee e6781cc7d8d7f6b3 fab899f66eeeaf2c
)

for f in $FILES; do
  [[ -f "$f" ]] || continue
  case "$f" in
    *.apk|*.xapk|*.dex|*.smali|*.jar|*.class|*.bin|*.hex|*.elf|*.axf|*.asm|*.nc|*.so|*.o|*.a)
      problem "$f: file type not allowed in the public repo";;
  esac
  size=$(stat -f%z "$f")
  (( size > 1500000 )) && problem "$f: $size bytes; large files need a deliberate review"
  sum=$(shasum -a 256 "$f" | cut -d' ' -f1)
  (( ${KNOWN[(Ie)$sum]} )) && problem "$f: matches a known HoMedics file"
  [[ "$f" == "$SELF" ]] && continue
  if grep -Iq . "$f" 2>/dev/null; then
    for p in $PATTERNS; do
      if hit=$(grep -n -i -E -m1 "$p" "$f"); then problem "$f: blocked pattern /$p/: ${hit:0:120}"; fi
    done
  fi
done

# Hashed identifier check (text files only).
if hits=$(print -l -- $FILES | grep -v -x "$SELF" | BLOCKED="${BLOCKED_WORDS[*]}" python3 -I -c '
import hashlib, os, re, sys
blocked = set(os.environ["BLOCKED"].split())
h = lambda w: hashlib.sha256(w.encode()).hexdigest()[:16]
for path in sys.stdin.read().split("\n"):
    try: text = open(path, encoding="utf-8").read().lower()
    except (OSError, UnicodeDecodeError): continue
    words = re.findall(r"[a-z0-9_]+", text)
    pairs = ["%s.%s" % m for m in re.findall(r"([a-z0-9_]+)[./]([a-z0-9_]+)", text)]
    found = sorted({w for w in set(words) | set(pairs) if h(w) in blocked})
    if found: print("%s: %d blocked identifier(s)" % (path, len(found)))
'); [[ -n "$hits" ]]; then
  for line in "${(@f)hits}"; do problem "$line"; done
fi

if (( fail )); then
  print -u2 "Publish guard failed. HoMedics code, firmware and content must never be published here."
  exit 1
fi
print "Publish guard: ${#FILES} files clean."
