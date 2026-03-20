# Forge

Git implementation from scratch. Written in Zig.

## Why?

Because the best way to understand Git is to build it. Because git's internals are fascinating and criminally under-documented. Because sometimes you want to know what's actually happening when you `git push`.

Forge isn't trying to replace Git. It's trying to explain Git by implementing it from first principles.

## Status

Early development. Building towards v0.1.0.

Working:
- [x] SHA-1 hashing
- [x] Object parsing (blob, tree, commit)
- [x] Object store (read/write with zlib compression)
- [x] `forge init`

In progress:
- [ ] References (branches, HEAD)
- [ ] Index (staging area)
- [ ] Basic commands (add, commit, log, status)

Future:
- [ ] Pack files and deltas
- [ ] Network protocol (clone, fetch, push)
- [ ] Full Git compatibility

## Building

Requires Zig 0.13+.

```bash
# Build
zig build

# Run tests
zig build test

# Install
zig build install --prefix ~/.local
```

## Usage

```bash
# Create a new repository
forge init

# More commands coming soon
```

## Architecture

Forge follows Git's internal structure:

- **Objects**: Content-addressable storage (blobs, trees, commits, tags)
- **References**: Named pointers to commits (branches, tags, HEAD)
- **Index**: Staging area for the next commit
- **Pack files**: Compressed object storage with delta encoding
- **Protocol**: Smart HTTP/SSH for clone, fetch, push

Each subsystem is implemented as a separate module in `src/`.

## Philosophy

1. Correctness over cleverness. Match Git's behavior exactly.
2. Readable over fast. This is educational code.
3. Complete over partial. Implement features fully or not at all.

## License

MIT

---

*Understanding Git by building Git.*
