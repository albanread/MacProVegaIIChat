# Building it

For anyone who wants to compile it themselves. You do not need any of this to use the
app — the released disk image is a finished thing.

## What you need

- macOS 13 or later, on an Intel Mac. The app is x86_64 only.
- The Xcode command line tools (`xcode-select --install`) and CMake.
- A checkout of the [IntelMacLlamaCpp](https://github.com/albanread/IntelMacLlamaCpp)
  fork of llama.cpp. Stock llama.cpp will compile, but it will not work properly on a
  Vega II — the fixes that make this app possible are in the fork.

## 1. llama.cpp, as static libraries

The app links llama.cpp straight in rather than shipping a separate engine binary, so it
needs the static libraries rather than an executable:

```bash
cd /path/to/llama.cpp
cmake -B build-rel -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DBUILD_SHARED_LIBS=OFF \
      -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_CURL=OFF
cmake --build build-rel -j --target llama-common
```

Two of those flags are not optional:

- `BUILD_SHARED_LIBS=OFF` — a shared build produces binaries whose rpath points at your
  build directory, so they cannot be relocated into an app bundle at all.
- `GGML_METAL_EMBED_LIBRARY=ON` — the Metal shader source has to travel inside the
  binary. It is compiled at runtime with the SIMD width of the card baked in as a macro,
  which is the whole mechanism behind the wave64 support, and is why a precompiled
  `.metallib` cannot be shipped instead.

`--target llama-common` pulls in everything else the app links: `llama`, `ggml`,
`ggml-base`, `ggml-cpu`, `ggml-metal`, `ggml-blas`.

## 2. The app

```bash
cd /path/to/MacProVegaIIChat
./build.sh
```

`build.sh` expects llama.cpp at `/Volumes/S/llama.cpp`. Set `LLAMA_CPP` to point somewhere
else:

```bash
LLAMA_CPP=~/src/llama.cpp ./build.sh
```

It checks for all nine static libraries and stops with the missing path if any are
absent. It cannot tell a stale library from a fresh one, though — so if you have changed
llama.cpp, rebuild the libraries **before** running it, not after.

The result is `MacVegaIIChat.app`: one binary, no dynamic library dependencies beyond
system frameworks, about 10 MB.

## 3. A disk image

```bash
./makedmg.sh          # produces MacVegaIIChat-<version>.dmg
```

Sign it before you give it to anyone. Unsigned, macOS **SIGKILLs** a downloaded copy,
and ad-hoc signing does not help — only a Developer ID signature plus notarisation by
Apple does.

## Checking it works

```bash
./test.sh             # loads a model, reads a document, drafts one, screenshots each step
./demo.sh --slow      # the same ground at a pace you can watch
```

`test.sh` needs a model already downloaded and the graphics card to itself. It leaves its
screenshots in `build/shots`.

## How the source is laid out

| | |
|---|---|
| `src/main.m` | the window, the model list, and the document work |
| `src/Llama.mm` | llama.cpp itself — loading, generating, the token cache |
| `src/DocText.m` | reading text out of documents, and the wording of every reading task |
| `src/Draft.m` | the draft window |
| `src/Sheets.m` | the settings and drafting panels |
| `src/Markdown.m` | just enough Markdown to read comfortably |
| `src/Scripting.m` | Apple Event support — see [SCRIPTING.md](SCRIPTING.md) |
