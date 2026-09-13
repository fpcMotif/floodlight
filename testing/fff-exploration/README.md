# FFF portable exploration

This directory drives the real `fff-test-harness` Rust workload. It covers portable FFF indexing, queries, filesystem changes, rebuilds, bounds, and readiness. It does not cover FSEvents, Swift integration, Launch Services, or AppKit.

## Local Bombadil validation

1. Install dependencies with `bun install --frozen-lockfile`, then install the pinned executable with `bun run install:bombadil`.
2. Build the harness from the repository root:

   ```sh
   ./testing/fff-contracts/materialize.sh
   cargo build --manifest-path .build/fff-contracts/source/Vendor/fff/Cargo.toml \
     -p fff-test-harness --release --locked
   ```

3. The install script downloads Bombadil `v0.7.4` from its GitHub release. The scripts verify its version and SHA-256 from `bombadil.env`.
4. Run `bun run check`, then `bun run campaign`. The campaign is limited to 30 seconds.

Set `BOMBADIL_RUN_ID` or `BOMBADIL_OUTPUT_PATH` to override recording details. Every run writes `metadata.json` and Bombadil's nonempty `trace.jsonl` under `artifacts/`. Metadata records terminal geometry, driver options, and both executable checksums. Bombadil 0.7.4's terminal driver has no seed option; replay uses the recorded action trace instead.

Replay with the recorded geometry and options:

```sh
bun run replay -- artifacts/RUN_ID
```

Replay can diverge because Bombadil terminal replay is not guaranteed deterministic. A divergence is a failed replay, not a new deterministic regression.

The JSONL harness protocol uses `id` and `op`. Supported operations are `init`, `query`, `put`, `rename`, `remove`, `quiesce`, `rebuild`, `observe`, and `shutdown`. Responses retain the command identity and carry `ok` plus bounded structured `data`. Bombadil checks result bounds, error freedom, complete query responses, and rebuild quiescence.

## Antithesis preparation

The container is intentionally Linux amd64 and builds the same Cargo package from the checked-in vendored FFF source.

```sh
docker build --platform linux/amd64 -f testing/fff-exploration/antithesis/Dockerfile -t fff-exploration:local .
docker compose -f testing/fff-exploration/antithesis/docker-compose.yaml up -d
docker compose -f testing/fff-exploration/antithesis/docker-compose.yaml exec fff-exploration \
  /opt/antithesis/test/v1/fff/singleton_driver_explore
```

The setup process writes the required `antithesis_setup` JSONL signal. The singleton command runs Bombadil against the same harness and fails on an empty trace, a property violation, or missing SDK output. Local Docker success proves image startup, command propagation, and local SDK emission only.

Cloud exploration is separate. It requires a tenant, prebuilt images in its registry, and a config image built from `antithesis/config.Dockerfile`. Record the image digest, Antithesis run identifier, duration, property reachability, SDK output, commands, and observations for each cloud run. Never report the local Compose check as cloud exploration.

Artifacts may contain fixture paths and command traces. Keep them for failures and reviewed campaign evidence; do not treat an empty trace as a successful run.
