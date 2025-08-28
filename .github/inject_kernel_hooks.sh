#!/usr/bin/env bash
#
# inject_kernel_hooks.sh — Kernel source hook injector for KSU integration
# Place in: scripts/inject_kernel_hooks.sh
#
# Usage: ./scripts/inject_kernel_hooks.sh
# Expects: $KERNEL_DIR env var or defaults to current working directory.
# Exit: non‑zero on any failure.

set -euo pipefail

# ---- Config ----
KERNEL_DIR="${KERNEL_DIR:-$(pwd)}"

# ---- Functions ----
inject_block() {
    local file="$1" pattern="$2" block="$3"
    if ! grep -Fq "$block" "$file"; then
        awk -v pat="$pattern" -v blk="$block" '
            $0 ~ pat { print; print blk; next }
            { print }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
        echo "[+] Injected block into $file after pattern: $pattern"
    else
        echo "[=] Block already present in $file"
    fi
}

# ---- Main ----
echo "[*] Injecting kernel hooks in $KERNEL_DIR"
cd "$KERNEL_DIR"

## === fs/exec.c hooks ===
block_exec_decl=$(cat <<'EOF'
#ifdef CONFIG_KSU
extern void ksu_handle_execveat(int *retval, struct filename *filename);
#endif
EOF
)

inject_block fs/exec.c "do_execveat_common\\(" "$block_exec_decl"

block_exec_call=$(cat <<'EOF'
#ifdef CONFIG_KSU
ksu_handle_execveat(&retval, filename);
#endif
EOF
)

inject_block fs/exec.c "do_execveat_common\\([^)]*\\)\\s*\\{" "$block_exec_call"

## === fs/open.c hooks ===
block_open_decl=$(cat <<'EOF'
#ifdef CONFIG_KSU
extern int ksu_handle_faccessat(int old_ret, int dfd, const char __user *filename, int mode);
#endif
EOF
)

inject_block fs/open.c "do_faccessat\\(" "$block_open_decl"

block_open_call=$(cat <<'EOF'
#ifdef CONFIG_KSU
ret = ksu_handle_faccessat(ret, dfd, filename, mode);
#endif
EOF
)

inject_block fs/open.c "return do_faccessat" "$block_open_call"

## === fs/stat.c hooks ===
block_stat_decl=$(cat <<'EOF'
#ifdef CONFIG_KSU
extern int ksu_handle_statx(int *old_ret, const char __user *filename);
#endif
EOF
)

block_stat_call=$(cat <<'EOF'
#ifdef CONFIG_KSU
ksu_handle_statx(&error, filename);
#endif
EOF
)

if grep -q "int vfs_statx" fs/stat.c; then
    inject_block fs/stat.c "int vfs_statx\\(" "$block_stat_decl"
    inject_block fs/stat.c "int vfs_statx\\([^)]*\\)\\s*\\{" "$block_stat_call"
else
    inject_block fs/stat.c "int vfs_fstatat\\(" "$block_stat_decl"
    inject_block fs/stat.c "int vfs_fstatat\\([^)]*\\)\\s*\\{" "$block_stat_call"
fi

echo "[✓] Hook injection complete."
