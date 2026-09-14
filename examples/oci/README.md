# Optional OCI distribution

OCI packaging is distribution only; it does not grant filesystem, network or
secret capabilities. The runtime must still receive explicit preopens and the
bridge/Component Model network policy.

After building the module:

```sh
make wasi
oras push localhost:5000/picoclaw-wasi:dev \
  --artifact-type application/vnd.wasm.content.layer.v1+wasm \
  build/picoclaw-wasi.wasm:application/wasm
```

The prototype does not require a registry, containerd, Docker Desktop or
runwasi. `oras` was not installed on the development host, so no registry push
is claimed. A future CI task should push to a disposable registry, inspect the
manifest media types, pull the exact digest, and run the pulled module with the
same Wasmtime preopens and secret policy.
