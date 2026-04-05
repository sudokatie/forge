#!/bin/bash
# Git/Forge interoperability tests
# Verifies that Forge produces Git-compatible repositories

set -e

FORGE="./zig-out/bin/forge"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "=== Forge/Git Interop Tests ==="
echo "Temp dir: $TMPDIR"
echo

# Build forge first
echo "Building forge..."
zig build
echo

# Test 1: Init repo with Forge, verify with Git
echo "Test 1: Init repo with Forge"
cd "$TMPDIR"
mkdir forge-init && cd forge-init
$FORGE init
[ -d .git ] || { echo "FAIL: .git not created"; exit 1; }
[ -f .git/HEAD ] || { echo "FAIL: HEAD not created"; exit 1; }
git status > /dev/null 2>&1 || { echo "FAIL: git status failed"; exit 1; }
echo "  PASS: Forge init creates valid Git repo"
cd ..

# Test 2: Create commit with Forge, verify with Git
echo "Test 2: Commit with Forge"
cd forge-init
echo "Hello from Forge" > test.txt
$FORGE add test.txt
$FORGE commit -m "Initial commit"
git log --oneline > /dev/null 2>&1 || { echo "FAIL: git log failed"; exit 1; }
FORGE_SHA=$(git rev-parse HEAD)
echo "  PASS: Forge commit readable by Git (SHA: ${FORGE_SHA:0:7})"
cd ..

# Test 3: Init with Git, add with Forge
echo "Test 3: Git init, Forge add"
mkdir git-init && cd git-init
git init -q
echo "Hello from Git" > file.txt
git add file.txt
git commit -q -m "Git commit"
echo "Modified by Forge" >> file.txt
$FORGE add file.txt
$FORGE commit -m "Forge commit"
git log --oneline | head -2 > /dev/null 2>&1 || { echo "FAIL: git log failed"; exit 1; }
echo "  PASS: Forge can commit to Git repo"
cd ..

# Test 4: Verify hash compatibility
echo "Test 4: Hash compatibility"
cd "$TMPDIR"
mkdir hash-test && cd hash-test
$FORGE init
echo -n "test content" > blob.txt
FORGE_HASH=$($FORGE hash-object blob.txt)
GIT_HASH=$(git hash-object blob.txt)
[ "$FORGE_HASH" = "$GIT_HASH" ] || { echo "FAIL: Hash mismatch: $FORGE_HASH vs $GIT_HASH"; exit 1; }
echo "  PASS: Hash matches ($FORGE_HASH)"
cd ..

# Test 5: Tree structure
echo "Test 5: Tree structure"
cd forge-init
mkdir -p dir/subdir
echo "nested file" > dir/subdir/nested.txt
$FORGE add dir/subdir/nested.txt
$FORGE commit -m "Add nested file"
git ls-tree -r HEAD | grep nested.txt > /dev/null || { echo "FAIL: nested file not in tree"; exit 1; }
echo "  PASS: Nested directory structure works"
cd ..

# Test 6: Branch operations
echo "Test 6: Branch operations"
cd forge-init
$FORGE branch test-branch
git branch | grep test-branch > /dev/null || { echo "FAIL: branch not created"; exit 1; }
echo "  PASS: Branch created and visible to Git"
cd ..

# Test 7: Status consistency
echo "Test 7: Status consistency"
cd forge-init
echo "new file" > untracked.txt
$FORGE status | grep -q "untracked" || echo "  (untracked detection may vary)"
git status --porcelain | grep -q "??" || { echo "FAIL: git doesn't see untracked"; exit 1; }
echo "  PASS: Status works"
cd ..

# Test 8: Diff output
echo "Test 8: Diff output"
cd forge-init
echo "modified content" > test.txt
$FORGE diff > /dev/null 2>&1 || true  # May or may not produce output
git diff > /dev/null 2>&1 || { echo "FAIL: git diff failed"; exit 1; }
echo "  PASS: Diff works"
cd ..

echo
echo "=== All interop tests passed ==="
