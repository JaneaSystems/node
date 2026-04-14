# Node.js PGO Training Scripts

Training workloads for Profile-Guided Optimization (PGO) builds on Windows
(Clang-CL / LLVM).

## What is PGO?

PGO uses runtime profile data to guide compiler optimizations (inlining,
branch prediction, code layout), typically improving throughput by 5-20%.

The process has three phases:

1. **Instrument** — Build with `-fprofile-generate` (produces `.profraw` files)
2. **Train** — Run representative workloads to collect profile data
3. **Optimize** — Merge `.profraw` → `node.profdata` via `llvm-profdata`,
   then rebuild with `-fprofile-use`

## Quick Start

Use `pgo.ps1` in the repo root (run from a VS Developer Command Prompt):

```powershell
# Full PGO build (all three phases)
.\pgo.ps1

# With LTO
.\pgo.ps1 -Lto ltcg

# Skip instrument phase (provide a pre-built instrumented binary)
.\pgo.ps1 -PgoGenNode ..\node_pgo_gen.exe

# Skip instrument + training (provide a pre-merged profdata file)
.\pgo.ps1 -ProfdataFile .\node.profdata
```

Or use `vcbuild.bat` directly:

```batch
vcbuild.bat pgo-generate
:: Run workloads with the instrumented Release\node.exe
:: Merge .profraw → node.profdata (requires llvm-profdata)
vcbuild.bat pgo-use
```

## Training Scripts

All scripts use only Node.js built-in modules (no npm dependencies).

| Script                   | What it exercises                                             |
| ------------------------ | ------------------------------------------------------------- |
| `pgo-http-server.js`     | llhttp parser, TCP stack, header serialization, JSON, routing |
| `pgo-json.js`            | V8 JSON parser/serializer, string allocation, GC pressure     |
| `pgo-crypto.js`          | OpenSSL (hashing, HMAC, AES, RSA, ECDSA, random, KDF)        |
| `pgo-streams-buffers.js` | Buffer C++ impl, stream state machine, back-pressure          |
| `pgo-fs.js`              | libuv fs operations, thread pool, path module                 |
| `pgo-async-patterns.js`  | V8 Promises, microtask queue, EventEmitter, timers            |
| `pgo-url-string.js`      | Ada URL parser, V8 string internals, regex JIT                |
| `pgo-compression.js`     | zlib, brotli C libraries, streaming compression               |
| `pgo-net.js`             | libuv TCP/pipe handles, c-ares DNS resolver                   |
| `pgo-module-loading.js`  | Module resolver, V8 script compilation, vm module             |
| `pgo-child-workers.js`   | Process spawning, Worker thread messaging, IPC                |

### Running Scripts

```bash
# Run all scripts (orchestrator)
node tools/pgo/pgo-run-all.js --duration=15

# Run specific scripts
node tools/pgo/pgo-run-all.js --scripts=http-server,json,crypto --duration=30
```

The `PGO_TRAINING_DURATION` environment variable (in milliseconds) controls
how long each script runs. Default is 15 seconds per script.

## Files

```
tools/pgo/
├── pgo-run-all.js          # Training orchestrator
├── pgo-http-server.js      # HTTP server + client workload
├── pgo-json.js             # JSON parse/stringify workload
├── pgo-crypto.js           # Crypto operations workload
├── pgo-streams-buffers.js  # Streams and Buffer workload
├── pgo-fs.js               # File system operations workload
├── pgo-async-patterns.js   # Promise/async, EventEmitter, timers workload
├── pgo-url-string.js       # URL parsing, string ops, regex workload
├── pgo-compression.js      # Gzip/brotli/deflate compression workload
├── pgo-net.js              # TCP networking and DNS workload
├── pgo-module-loading.js   # Module require/import, VM compilation workload
├── pgo-child-workers.js    # Child processes, Worker threads workload
└── README.md               # This file
```
