# Forge

A Git implementation in Zig. Because understanding Git internals requires more than reading the docs -- you have to build the thing.

## Why Forge?

Git is everywhere. Everyone uses it. Almost nobody understands how it actually works under the hood. Forge is a from-scratch reimplementation that forces you to confront the object model, the index, the pack format, and the protocol. No shortcuts.

12,000 lines of Zig. 172 tests. Every object type, every command, built from first principles.

## Features

- Object storage: blobs, trees, commits, tags
- References: branches, HEAD, packed-refs, symbolic refs
- Index (staging area) with full operations
- All basic commands: init, add, commit, log, status, branch, checkout, tag
- Diff algorithm (Myers unified diff)
- Pack file reading (v2 index, delta application, thin pack resolution)
- HTTP smart protocol (ref discovery, pack negotiation)
- Clone, fetch, push (refs + pack transfer)
- LFS support (pointer files, batch API, smudge/clean filters, gitattributes)
- Interactive rebase (edit, squash, reorder, abort/continue/skip)
- Three-way merge with conflict detection and markers
- Submodule management (init, update, status, sync, recursive clone)
- Gitattributes parsing

## Building

```bash
zig build
zig build test  # 172 tests
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

# Tags
forge tag v1.0
forge tag v1.1 -m "Release 1.1"

# Diff
forge diff
forge diff --staged

# Remotes
forge clone https://github.com/user/repo.git
forge fetch origin
forge push origin main

# Interactive rebase
forge rebase -i HEAD~3
forge rebase --continue
forge rebase --abort
forge rebase --skip

# Submodules
forge submodule init
forge submodule update
forge submodule status
forge clone --recursive https://github.com/user/repo.git

# LFS
forge lfs install
forge lfs track "*.psd"
forge lfs pull
```

## Architecture

```
forge/
├── src/
│   ├── cmd/          # CLI commands (init, add, commit, rebase, submodule, etc.)
│   ├── rebase/       # Interactive rebase engine (todo, conflict resolution)
│   ├── merge/        # Three-way merge with conflict detection
│   ├── submodule/    # Submodule config, status, .gitmodules parsing
│   ├── lfs/          # LFS pointer files, batch API, smudge/clean filters
│   ├── object.zig    # Object storage and parsing
│   ├── index.zig     # Staging area operations
│   ├── refs.zig      # References and packed-refs
│   ├── pack.zig      # Pack file reading and delta application
│   ├── diff.zig      # Myers diff algorithm
│   ├── transport.zig # HTTP smart protocol
│   └── repository.zig # Repository abstraction
└── build.zig
```

## Not Yet Implemented

- Pack file generation (for push data transfer)
- Proper zlib compression (using system zlib for now)
- SSH authentication (HTTP basic auth works)
- Shallow clones
- Worktrees

## License

MIT

---

*Built by Katie. Because reading the Git internals docs and building the thing are very different experiences.*
