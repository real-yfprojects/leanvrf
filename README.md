# leanvrf
Workflow to attest successful lean verification of a given statement with unfalsifiable provenance and integrity guarantees

When an possibly dishonest actor claims to have proven a mathematical statement,
they can supply a formal lean formalization of the statement and a formal proof of it.
However, this proof needs to be verified by a trusted lean kernel, which may entail large runtime costs.
Thus it is desirable to have the untrusted prover provide a certificate (attestation) of the verification
running on their resources.
Cryptographic techniques like secure multiparty computation or SNARKs (Succinct Non-interactive ARgument of Knowledge)
exhibit nice properties for this purpose, but there computational overhead make them impractical for most applications
including lean proofs.
Thus this repo introduces a secure computing environment on top of github actions that provers can run from their
repositories and accounts and thus pay for the computational costs themselves, while still being able
to provide an attestation of workflow integrity and provenance. That is a certificate that this exact
workflow has been run with the attested inputs and outputs.
Verifying these attestations is very cheap and allows other parties to trust
the correctness of the proof without having to run the expensive verification themselves.

On top of ensuring that a trusted lean environment was used for verification,
one has to deal with adversarial theorem descriptions (challenges) and proof theories (solutions).
Not only can they try to exploit unpatched bugs in a lean kernel, add axioms or redefine objects referenced in the statement,
but lean theories allow arbitrary code execution inside the workflow.

This workflow thus compiles the challenge lean theory and the solution lean theory
separate from each other (using lean4export) in a sandboxed environment,
uses lean comparator to ensure that the challenge and solution theories match and
don't employ any dishonest tricks and checks the solution theory for correctness
not only using the official lean kernel, but also using nanoda and lean4lean.
This helps guarding against exploits that are only present in one of the kernels.
Note that comparator, nanoda and lean4lean all run in separate sandboxes.

## Adversarial model

We model three parties which may coincide: <br>
The challenger, who formalizes a problem in a challenge lean theory.<br>
The prover, who claims to have proven a specified challenge and provides a lean proof.<br>
The verifier, who wants to know whether the prover's claim is true in respect to a given challenge.<br>

The adverserial model takes the perspective of the verifier and assumes that the
prover may be dishonest and adverse.
We assume the challenger to be honest, that is the verifier trusts the challenge lean theory
-- e.g. by checking its source code and verifying that it formalizes the intended problem.

The prover runs this workflow and wants to convince the verifier by providing
an attestation of a passing verification.
They control the repository the workflow is executed in, the inputs to the workflow
**including** the challenge and solution lean theories provided to the workflow.
That means that while the claimed challenge file is assumed to be honest,
the prover may run the workflow with an adversarial challenge to trick the verifier into producing an attestation for the claimed challenge.
They may run on a self-hosted runner, which we have to defend against, since
we cannot trust self-hosted runners.
What we do trust is github itself.
Specifically that github-hosted runners are fresh, unmodified machines,
and that the OIDC identity and the sigstore signature produced by `actions/attest`
can only be obtained by the workflow they claim to come from.
We trust our pinned toolchain dependencies and the tools used in the workflow.

In the lean kernels we only put a 1-out-of-n trust. Thus we only assume
that not all of the (currently) three kernels (lean, nanoda, lean4lean) can be exploited at a time.

Since the prover pays for the runtime, we don not care about DoS type attacks like consuming lots of CPU time or memory or disk space.

This leaves the prover still with lots of attack vectors:
- arbitrary code execution when compiling the lean files,
- adding axioms or hiding sorrys,
- shadowing or redefining names the challenge relies on,
- exploit soundness bugs in a specific lean kernel
- and possibly many more.

## Mitigations and Security Considerations

### Attestation contents

The workflow signs an [in-toto Statement](https://github.com/in-toto/attestation/blob/main/spec/v1/statement.md)
via `actions/attest`. What a verifier learns is split over two layers:

| Fact | Attestation | Why there |
|---|---|---|
| workflow@commit (`job_workflow_ref`, `job_workflow_sha`) | Sigstore certificate (Fulcio extensions, `1.3.6.1.4.1.57264.1.9` / `.10`) | Comes from GitHub's OIDC token; cannot be forged by the prover |
| GitHub-hosted vs. self-hosted runner (`runner_environment`) | Certificate (`1.3.6.1.4.1.57264.1.11`) | Same |
| Prover's repository, ref, run URL, trigger | Certificate (`.12`-`.21`) | Same |
| Time of signing | Certificate validity / Rekor `integratedTime` | Same |
| Challenge and solution digests | Statement `subject` **and** predicate `challenge` / `solution` | `subject` lets `gh attestation verify <file>` find the attestation; the predicate copies bind each digest to its *role* (trusted challenge vs. untrusted solution) |
| Theorem name, result, axiom policy, pinned toolchain | Predicate ([schemas/leanvrf-v1.json](schemas/leanvrf-v1.json)) | Computed by the trusted workflow code; not expressible in the certificate |

The predicate therefore contains **no** workflow identity, runner type, repository or timestamp fields.
A verifier MUST take those from the certificate and MUST NOT accept a predicate-supplied value in their place.
The predicate's `policy` and `toolchain` blocks are fully determined by `job_workflow_sha`; they are repeated
so that consumers can read what was checked without checking out this repository, and can be cross-checked
against it via `toolchain.lock.digest.sha256`.
The only third-party code the attest job runs besides `jq` is `check-jsonschema`, installed from
[scripts/requirements.txt](scripts/requirements.txt) with `pip install --require-hashes`, so every
Python package (including transitive dependencies) is pinned by version and sha256.

Predicate type: `https://github.com/theproofnetwork/leanvrf/predicate/v1`.
Artifact references use in-toto `ResourceDescriptor`s ([schemas/in-toto-v1.json](schemas/in-toto-v1.json)),
with leanvrf-specific facts under `annotations`, in-toto's designated extension point.

### Toolchain pinning and tool releases

The workflow never installs Lean or the verifier tools from a package manager, container tag or
Actions cache. Everything comes from [toolchain.lock](toolchain.lock), which is read from the trusted
checkout at `job.workflow_sha` and therefore fixed by the attested workflow identity:

- `lean` points at an official `leanprover/lean4` release tarball and its sha256.
- `tools` lists the prebuilt binaries (`lean4export`, `comparator`, `nanoda_bin`, `lean4lean`, `landrun`)
  with their source repository, the exact commit they were built from, the build recipe, the download
  URL and the sha256 of the resulting binary.

[scripts/provision-toolchain.sh](scripts/provision-toolchain.sh) downloads each artifact over HTTPS and
rejects it unless the hash matches; the hash of the lockfile itself ends up in the predicate as
`toolchain.lock.digest.sha256`. Caching is deliberately avoided: in a reusable workflow `actions/cache`
is scoped to the *caller's* repository, i.e. the prover's, and could be seeded with tampered binaries.

#### Building and publishing the tools

The tool binaries are built by [build-tools.yml](.github/workflows/build-tools.yml)
(`workflow_dispatch`, maintainers only) via [scripts/build-tools.sh](scripts/build-tools.sh):
each tool is cloned at its pinned commit and compiled against the locked Lean release itself
(not via `elan`), so the Lean-based tools accept exactly the `.olean` files the verification
workflow produces. The Rust and Go compilers for the non-Lean tools come from the hash-pinned
official tarballs in the lockfile's `build_toolchains` block rather than from the runner image,
so a rebuild of the same lockfile uses the same compilers.
The binaries get an `actions/attest-build-provenance` attestation and are
attached to a GitHub release. The run's summary prints a copy of `toolchain.lock` with the real
hashes filled in; committing that copy is how a new toolchain is rolled out.

#### Release tag scheme

Tool releases are tagged `tools-<lean version>-<build number>`, e.g. `tools-v4.33.0-1`:

| Part | Meaning |
|---|---|
| `tools-` | Separates tool releases from releases of the workflow itself. |
| `v4.33.0` | The Lean release the binaries were built against. Lean-based tools embed the compiler's githash and reject `.olean`s from any other version, so a Lean bump always means a new set of binaries. |
| `-1` | Build counter within that Lean version. Bumped whenever anything else changes (a tool commit, a build fix, a toolchain used for building) without Lean changing. |

Security does not depend on the tag: `provision-toolchain.sh` enforces the sha256 next to each URL,
and the whole lockfile is hashed into the attestation. A tag that was deleted and recreated with
different assets simply fails verification.

<!-- TODO Document usage -->
<!-- TODO Document security considerations and mitigations -->
<!-- TODO verifier script -->
<!-- TODO resolve todos in workflow -->
<!-- TODO add git pre-commit hooks to ensure formatting, pinned workflows, security related stuff, ... (and can be used in CI) -->