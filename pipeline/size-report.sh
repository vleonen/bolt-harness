#!/usr/bin/env bash
# Report the stripped size and the section/segment alignment overhead of each
# binary variant.
#
# The script is architecture-neutral: the same invocation works on aarch64 and
# x86_64 (only the target's regular page size differs, which is what
# --no-huge-pages switches to).
#
# Usage: size-report.sh [mode...]     (default: every mode in VALID_MODES)
#
# Env: APP, NOHUGE (to include bolt-rewrite-nohuge), plus the usual
# lib/common.sh knobs.
#
# For each variant it strips a temp copy (the deployed runtime image: the
# -Wl,-q .rela.* sections and the symbol table are not loaded) and reports:
#   size      stripped file size (bytes)
#   delta     vs the baseline stripped size
#   .text     .text sh_addralign (bytes)
#   LOAD      maximum PT_LOAD p_align (bytes)
#   seghole   file padding between consecutive PT_LOAD segments (bytes)
#   gaps      stripped - section bytes - ELF/segment/section-header bytes
#             (inter-section alignment padding + segment holes)
#   gaps%     gaps as a fraction of the stripped file
set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$HARNESS_ROOT/lib/common.sh"

MODES=("$@")
[ ${#MODES[@]} -eq 0 ] && MODES=($VALID_MODES)
for m in "${MODES[@]}"; do mode_valid "$m" || die "unknown mode '$m'"; done

# _elf_counts <file> -> "<content_bytes> <header_bytes> <text_align> <shnum>"
# content is the sum of all non-NOBITS section bytes present in the file;
# header_bytes is the ELF + program-header + section-header table overhead.
_elf_counts() { # <file>
  local f="$1" hdr eh pe pn se sn
  hdr="$(readelf -h "$f")"
  eh="$(awk -F': *' '/Size of this header/       { print $2 }' <<<"$hdr")"
  pe="$(awk -F': *' '/Size of program headers/   { print $2 }' <<<"$hdr")"
  pn="$(awk -F': *' '/Number of program headers/ { print $2 }' <<<"$hdr")"
  se="$(awk -F': *' '/Size of section headers/   { print $2 }' <<<"$hdr")"
  sn="$(awk -F': *' '/Number of section headers/ { print $2 }' <<<"$hdr")"
  readelf -SW "$f" \
    | sed -E 's/^[[:space:]]*\[[[:space:]]*([0-9]+)\][[:space:]]+/\1 /' \
    | awk -v eh="$eh" -v pe="$pe" -v pn="$pn" -v se="$se" -v sn="$sn" '
      function h2d(s,   i,c,n,d) {
        sub(/^0x/, "", s); n = 0
        for (i = 1; i <= length(s); i++) {
          c = tolower(substr(s, i, 1))
          d = index("0123456789abcdef", c) - 1
          if (d < 0) d = 0
          n = n * 16 + d
        }
        return n
      }
      /^[0-9]+ / {
        idx = $1; name = $2; typ = $3; off = $5; size = $6; al = $NF
        if (idx == 0 || typ == "NOBITS") next
        if (h2d(off) > 0 && h2d(size) > 0) {
          content += h2d(size)
          if (name == ".text") ta = al
        }
      }
      END { printf "%d %d %d %d\n", content, eh + pe*pn + se*sn, ta, sn }'
}

# _seg_stats <file> -> "<hole_bytes> <max_load_align>"
_seg_stats() { # <file>
  readelf -lW "$1" | awk '
    function h2d(s,   i,c,n,d) {
      sub(/^0x/, "", s); n = 0
      for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1))
        d = index("0123456789abcdef", c) - 1
        if (d < 0) d = 0
        n = n * 16 + d
      }
      return n
    }
    $1 == "LOAD" {
      n++
      off[n] = h2d($2)
      end[n] = h2d($2) + h2d($5)
      a = h2d($NF)
      if (a > ma) ma = a
    }
    END {
      for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
          if (off[j] < off[i]) {
            t = off[i]; off[i] = off[j]; off[j] = t
            t = end[i]; end[i] = end[j]; end[j] = t
          }
      hole = 0
      for (i = 2; i <= n; i++) {
        g = off[i] - end[i - 1]
        if (g > 0) hole += g
      }
      printf "%d %d\n", hole, ma
    }'
}

printf '%-14s %-22s %12s %8s %9s %10s %11s %11s %7s\n' \
  app/mode variant size delta .text LOAD seghole gaps gaps%

for mode in "${MODES[@]}"; do
  base_size=""
  for which in $VALID_WHICH; do
    bin="$(which_binary "$mode" "$which")"
    if [ ! -x "$bin" ]; then
      printf '%-14s %-22s %12s\n' "$APP/$mode" "$which" "(missing)"
      continue
    fi
    tmp="$(mktemp)"
    if strip -o "$tmp" "$bin" >/dev/null 2>&1; then f="$tmp"; else f="$bin"; fi
    size="$(stat -c%s "$f")"

    read -r content headers ta shnum <<EOF
$(_elf_counts "$f")
EOF
    read -r hole lalign <<EOF
$(_seg_stats "$f")
EOF

    gaps=$(( size - content - headers ))
    [ -n "$base_size" ] || base_size="$size"
    delta="$(awk -v a="$size" -v b="$base_size" \
      'BEGIN { if (b > 0) printf "%+.2f%%", 100 * (a - b) / b; else print "n/a" }')"
    pct="$(awk -v g="$gaps" -v s="$size" \
      'BEGIN { if (s > 0) printf "%.2f%%", 100 * g / s; else print "n/a" }')"

    printf '%-14s %-22s %12s %8s %9s %10s %11s %11s %7s\n' \
      "$APP/$mode" "$which" "$size" "$delta" "$ta" "$lalign" "$hole" "$gaps" "$pct"
    rm -f "$tmp"
  done
done
