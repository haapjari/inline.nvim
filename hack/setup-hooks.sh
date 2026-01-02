#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOOKS_DIR="${REPO_ROOT}/.git/hooks"

echo "setting up git hooks..."

cat > "${HOOKS_DIR}/pre-commit" << 'EOF'
#!/usr/bin/env bash

# pre-commit hook for inline.nvim
# runs syntax check, lint, and tests before allowing a commit.

set -o errexit
set -o nounset
set -o pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "running pre-commit checks..."
echo ""

cd "${REPO_ROOT}"

if ! make verify test; then
    echo "=========================================="
    echo "pre-commit FAILED"
    echo "=========================================="
    echo ""
    echo "fix the issues above or use 'git commit --no-verify' to skip."
    exit 1
fi

echo "=========================================="
echo "pre-commit PASSED"
echo "=========================================="
EOF

chmod +x "${HOOKS_DIR}/pre-commit"

echo "git hooks installed successfully!"
echo ""
echo "installed hooks:"
echo "  - pre-commit: runs syntax check, lint, and tests"
echo ""
echo "to skip hooks temporarily: git commit --no-verify"
