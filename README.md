# forge

A Git implementation in Zig. Learning project to understand Git internals.

## Status

Work in progress. Currently implements:
- Object storage (blobs, trees, commits)
- References (branches, HEAD)
- Index (staging area)
- Basic commands: init, add, commit, log, status, branch, checkout
- Diff algorithm (Myers)
- Pack file reading
- Protocol encoding (pktline)

## Building

```bash
zig build
zig build test
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
```

## Not Yet Implemented

- Pack file writing
- Network protocol (clone, fetch, push)
- Proper zlib compression
- Merge/rebase
- Remote tracking

## License

MIT
