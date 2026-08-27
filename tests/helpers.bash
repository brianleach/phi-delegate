# Shared helpers for the phi-delegate bats suite. Load with: load helpers

phi_repo_root() {
  cd "${BATS_TEST_DIRNAME}/.." && pwd
}

setup_fixture_repo() {
  local repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$repo"
  git init -q -b main "$repo"
  git -C "$repo" config user.email "bats@example.invalid"
  git -C "$repo" config user.name "Bats Test"
  printf 'fixture seed\n' >"${repo}/seed.txt"
  git -C "$repo" add seed.txt
  git -C "$repo" commit -q -m "seed commit"
  cd "$repo" || return 1
}

# Put a fake `claude` on PATH that records its argv and environment, edits
# a file, and writes a handoff, so delegate.sh can run offline.
install_fake_claude() {
  local bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$bin"
  cat >"${bin}/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FAKE_CLAUDE_ARGS}"
env | grep -E '^(ANTHROPIC_|CLAUDE_CONFIG_DIR|DISABLE_)' | sort >"${FAKE_CLAUDE_ENV}"
if [ -f .phi-task.md ]; then
  printf 'delegate wrote this\n' >>seed.txt
  printf '%s\n' "${FAKE_HANDOFF:-Updated seed.txt. Ran no tests (none exist).}" >.phi-handoff.md
fi
echo '{"type":"result","result":"done"}'
FAKE
  chmod +x "${bin}/claude"
  export PATH="${bin}:${PATH}"
  export FAKE_CLAUDE_ARGS="${BATS_TEST_TMPDIR}/claude.args"
  export FAKE_CLAUDE_ENV="${BATS_TEST_TMPDIR}/claude.env"
}

export_delegate_env() {
  export PHI_DELEGATE_API_KEY="test-key-not-real"
  export PHI_DELEGATE_ZDR_ATTESTED=1
  export PHI_DELEGATE_CONFIG_DIR="${BATS_TEST_TMPDIR}/cfg"
  export PHI_DELEGATE_ENV_FILE="${BATS_TEST_TMPDIR}/no-such-env"
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
}
