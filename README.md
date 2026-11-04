# setup-git-action

A composite GitHub Action that provisions a temporary Gitea instance, creates and seeds a test repository, and deploys/configures [`git-integrator`](https://charmhub.io/git-integrator) for Juju charm integration tests.

The intended consumer experience is deliberately small:

```yaml
- name: Set up Git integration
  id: git
  uses: YOUR_ORG/setup-git-action@v1
```

No user-supplied Gitea URL, Gitea credentials, or repository files are required in this first version. The action generates temporary credentials and a sample repository itself.

## What it does

1. Uses `charmed-kubernetes/actions-operator` to prepare Juju and an ephemeral MicroK8s substrate when no controller is already present.
2. Deploys Gitea into the Kubernetes cluster in a dedicated `gitea` namespace.
3. Creates a temporary Gitea administrator and API token.
4. Creates a private repository and pushes a README and sample data file to the requested branch.
5. Creates a Juju secret using the `credentials-personal-access-token` field, grants it to `git-integrator`, and configures the charm.
6. Waits for `git-integrator` to become active.

Gitea uses an in-cluster Kubernetes Service. The repository URL returned by the action is therefore an internal cluster URL intended for workloads in the same cluster, not a public URL for a developer's browser.

## Inputs

All inputs are optional. Defaults are suitable for a basic smoke test.

| Input | Default | Description |
|---|---|---|
| `repository-name` | `charm-test-repo` | Temporary repository name |
| `tracking-ref` | `main` | Branch to seed and configure |
| `path` | `/` | Repository path |
| `model` | `git-integration` | Juju model name |
| `git-integrator-channel` | `1.0/edge` | CharmHub channel |
| `gitea-image` | `docker.gitea.com/gitea:1.23.8` | Gitea image |

## Outputs

| Output | Description |
|---|---|
| `repository-url` | In-cluster repository URL configured in the charm |
| `repository-name` | Created repository name |
| `tracking-ref` | Configured branch |
| `git-integrator-app` | Juju application name (`git-integrator`) |
| `juju-model` | Juju model used by the action |

Example:

```yaml
- name: Set up Git integration
  id: git
  uses: YOUR_ORG/setup-git-action@v1

- name: Deploy and integrate my charm
  shell: bash
  run: |
    juju deploy my-charm
    juju integrate git-integrator my-charm
```

The target charm must be deployable into the same Juju model and substrate for this simple integration pattern. If it requires a different model or substrate, the test will need cross-model integration or a different environment strategy.

## Testing this repository

The workflow at `.github/workflows/test-action.yaml` is an end-to-end example. It:

- invokes the action with defaults;
- deploys `airflow-coordinator-k8s`;
- integrates it with `git-integrator`;
- checks that the expected repository URL and branch appear in `juju show-unit` output;
- removes the test model and Gitea namespace.

Run it using **Actions → Test setup-git-action → Run workflow**, or let it run on a pull request.

## Important first-version limitations

This is an initial implementation scaffold and must be validated against the exact Juju, MicroK8s, Gitea, and charm versions used by the project before being relied on in CI.

- The action uses an ephemeral MicroK8s substrate on GitHub-hosted Ubuntu runners. This is separate from a developer's existing Juju cloud.
- `charmed-kubernetes/actions-operator@main` is used to mirror the reference Kafka action. Before publishing, pin this dependency to a reviewed commit SHA.
- The action assumes the `git-integrator` charm can be deployed into the MicroK8s-backed Juju model and that the target charm can share that model. Verify this with the actual charm metadata and integration endpoints.
- The Gitea manifest uses `emptyDir` storage and SQLite because this is disposable test data, not a production Gitea deployment.
- The Gitea token is written to the runner job environment for subsequent composite steps and is not exposed as a public action output. It is registered with GitHub Actions log masking.
- Composite actions do not have a native post/cleanup hook. Consumers of this first version should use a cleanup step with `if: always()` as shown in the test workflow. The GitHub-hosted runner itself is ephemeral, but explicit cleanup makes the lifecycle clear.
- The current test verifies relation-data propagation only; it does not test Airflow's subsequent use of repository files.

## Future work

- Add an optional input for a directory of user-provided files to seed into Gitea.
- Add an optional repository initialization mode (sample files vs. caller-provided files).
- Avoid passing the Gitea token through action outputs.
- Add robust cleanup and failure diagnostics.
- Pin all third-party actions and container images to immutable versions/digests.
- Consider a reusable workflow that wraps setup, target charm deployment, integration verification, and cleanup.

## License

Apache-2.0. See [LICENSE](LICENSE).
