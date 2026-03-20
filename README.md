# forge

A Git implementation in Zig. Learning project to understand Git internals.

## Status

Nearly complete! Implements:
- Object storage (blobs, trees, commits)
- References (branches, HEAD, packed-refs)
- Index (staging area)
- All basic commands: init, add, commit, log, status, branch, checkout
- Diff algorithm (Myers unified diff)
- Pack file reading (v2 index, delta application)
- HTTP smart protocol (ref discovery)
- Clone, fetch, push commands (refs only, pack transfer WIP)

## Building

```bash
zig build
zig build test  # 51 tests
```

## Usage

```bash
# Initialize repository
forge init

# Stage files
forge add file.txt

# Commit
forge commit -m "initial commit"

# View history
forge log
forge log --oneline -n5

# Check status
forge status

# Branches
forge branch           # list
forge branch feature   # create
forge checkout feature # switch
forge checkout -b new  # create and switch

# Remotes (refs only)
forge clone https://github.com/user/repo.git
forge fetch origin
forge push origin main
```

## Not Yet Implemented

- Pack file generation/upload (push data)
- Pack file download (clone/fetch data)
- Proper zlib compression
- Merge/rebase
- Authentication (SSH keys)

## License

MIT
