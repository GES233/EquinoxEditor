---
name: diffsinger-pure-fp
description: Inspect, implement, debug, or verify Pure-FP DiffSinger inference by replacing unseeded ONNX random operators with explicit host-noise inputs. Use when adapting the Equinox/Neume Python-worker implementation or the coconut_intervention Ortex/Rust-NIF implementation, investigating model-specific noise tensor shapes, threading seed/cache identity, or proving deterministic rendering.
---

# DiffSinger Pure-FP Surgery

Turn a stochastic DiffSinger pipeline into a function of explicit inputs and `seed` without modifying the original voicebank files.

This Skill is based on two implementations:

- **Equinox / Neume** — ONNX runs inside one persistent Python worker. Generate NumPy `float32` noise in that worker; do not send large tensors through NDJSON or BEAM.
- **coconut_intervention / coconut_oi** — ONNX runs through Ortex in BEAM steps. Generate noise with the deterministic Rust NIF and append tensors to the Ortex input tuple.

Do not blindly copy one repository's tensor constants into another voicebank.

## Read first

For Neume, inspect:

- `apps/neume/lib/neume/engine/diff_singer_fp.ex`
- `apps/neume/lib/neume/engine/diff_singer_pipeline.ex`
- `apps/neume/lib/neume/engine/diff_singer_worker.ex`
- `apps/neume/priv/diffsinger/worker.py`
- `apps/neume/priv/fp/freeze_noise.py`
- `apps/neume/priv/fp/fp_acceptance.exs`

For the reference Ortex implementation, locate the `coconut_intervention` checkout and inspect:

- `apps/coconut_oi/lib/coconut_oi/diffsinger/fp.ex`
- `apps/coconut_oi/lib/coconut_oi/diffsinger/pipeline.ex`
- `apps/coconut_oi/priv/fp/freeze_noise.py`
- `apps/coconut_oi/native/coconut_oi_noise/src/lib.rs`
- `apps/coconut_oi/priv/fp/fp_determinism.exs`

Never assume the second checkout's location; discover it first.

## Workflow

### 1. Establish permission and asset boundaries

Confirm whether the voicebank/model license permits local modification and, separately, redistribution of derived ONNX files. Record the evidence when distribution matters.

Always:

- treat original voicebank models as read-only;
- write derived models to a separate ignored build/cache directory;
- key that directory by the original voicebank digest and surgery/noise version;
- never commit derived ONNX files accidentally.

### 2. Inventory stochastic operators

Inspect every model used by the pipeline, including graph subgraphs:

- `RandomNormalLike`
- `RandomUniform`
- other unseeded `Random*` operators

For each operator record:

- model/step name;
- exact node name and output consumers;
- distribution;
- whether consumers occur inside a Loop/If subgraph;
- runtime shape rule;
- whether the operator is initial diffusion/excitation noise or fresh noise generated during iteration.

Only replace noise whose semantics are understood. Rewire consumers recursively when they live in subgraphs.

### 3. Derive shapes from the target model

Trace the random operator's `Like` input or its shape-building chain, commonly:

```text
Constants + dynamic frame count
  → Concat
  → ConstantOfShape
  → RandomNormalLike
```

Map only genuinely dynamic dimensions to manifest symbols:

- `"frames"` → aligned total frame count;
- `"samples"` → `frames * hop_size`.

Keep model-specific static dimensions from the target graph.

Known examples are evidence, not universal constants:

| Model | Qixuan | Asaritsu |
| --- | --- | --- |
| pitch | `[1, 1, 64, "frames"]` | same |
| variance | `[1, 2, 36, "frames"]` | `[1, 4, 16, "frames"]` |
| acoustic | `[1, 1, 128, "frames"]` | same |
| vocoder | phase `[1,1,9]`, excitation `[1,"samples",9]` | those target random nodes may be absent |

A dynamically declared ONNX input can pass `onnx.checker` while carrying the wrong runtime shape. A real inference probe is mandatory.

### 4. Perform surgery

For every approved random node:

1. Add a `FLOAT` graph input at the end of the original input list.
2. Rewire all consumers from the random node output to the new input, recursively through subgraphs.
3. Remove the random node.
4. Run `onnx.checker.check_model`.
5. Save to a separate output directory.
6. Emit `fp_manifest.json` with derived model paths and ordered noise specs.

If an optional known node is absent, verify that the model is already deterministic at that point and emit no noise spec for it. Do not invent an input.

### 5. Choose the host-noise branch

#### Python-worker branch (Neume)

- Load derived model paths from the manifest when the worker starts.
- Derive an independent stream from `noise_version + seed + stage + spec index`.
- Generate `float32` arrays inside Python.
- Resolve `frames` and `samples` from actual aligned durations.
- Add noise arrays to the session feed by manifest input name.
- Keep the worker identity sensitive to voicebank digest, manifest digest, noise version, seed, Python, and worker path.

Do not transmit noise arrays over NDJSON.

#### Ortex/BEAM branch (coconut_intervention)

- Load manifest specs into the FP struct.
- Use the fixed Rust RNG implementation for large tensors.
- Resolve shapes in the step context.
- Append host-backed tensors positionally after original Ortex inputs.
- Give each stochastic step a distinct salt/stream.
- Include `seed` and `fp_noise_version` in every stochastic step's cache keys.

Do not generate sample-domain vocoder noise with interpreted `Nx.BinaryBackend`; it is prohibitively slow.

### 6. Thread identity consistently

The following must affect worker/session identity and render cache identity:

- original voicebank/model digest;
- FP versus stock mode;
- manifest **content digest**, not path alone;
- noise algorithm version;
- seed;
- inference steps and other existing model inputs.

Bump the cache schema version when introducing FP to an existing cache. Rebuilding a manifest at the same path must not reuse a worker holding stale sessions.

Keep stock as an explicit fallback. In Neume the intended policy is default FP with `fp: false` for stock.

### 7. Verify with three gates

Run with render cache disabled.

1. **Determinism:** same input + same seed twice → byte-identical intermediate/final output.
2. **Noise liveness:** change only seed → output differs.
3. **Semantic sanity:** stock and FP preserve shape, duration, finite values, non-silence, and broadly comparable signal/model statistics.

Use a sufficiently long representative phrase for tight statistical tolerances. A one-second take has high stock variance; if using it, document the wider threshold and print exact statistics rather than hiding the choice.

For Neume, run:

```sh
cd apps/neume
mix compile --force --warnings-as-errors
mix test
python -m py_compile priv/fp/freeze_noise.py priv/diffsinger/worker.py
mix run priv/fp/fp_acceptance.exs
```

Real Python workers may require sandbox escalation because Erlang `Port.open` can be blocked.

## Failure diagnosis

| Symptom | Likely cause |
| --- | --- |
| `MatMul dimension mismatch` inside diffusion Loop | Host-noise static dimensions copied from another voicebank |
| `missing ONNX inputs: host_noise` | Derived model loaded but manifest/noise feed not loaded |
| Same seed differs | A random node remains, seed is not stable, or stock model/session was loaded |
| Different seeds match | Noise input is ignored, silently zeroed, or cache key omits seed |
| Rebuilt manifest has no effect | Worker identity uses only manifest path, not content digest/version |
| FP is much slower | Noise generated through interpreted Nx or moved across process/protocol boundaries |
| `onnx.checker` passes but inference fails | Dynamic input declaration concealed an incorrect runtime shape |

## Completion report

Report:

- voicebank and model digest;
- random operators found/replaced/skipped;
- manifest directory and noise version;
- host branch used;
- same-seed and different-seed hashes;
- stock/FP sanity metrics and threshold rationale;
- build/test commands and results;
- remaining license or cross-runtime reproducibility limits.
