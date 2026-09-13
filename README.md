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

<!-- TODO Document usage -->
<!-- TODO Document security considerations and mitigations -->
<!-- TODO verifier script -->
<!-- TODO resolve todos in workflow -->
<!-- TODO add git pre-commit hooks to ensure formatting, pinned workflows, security related stuff, ... (and can be used in CI) -->