# update-image action

Updates a kustomize overlay's image tag in this GitOps repository and pushes the
commit. Service repositories call it after building and pushing an image to
OCIR, so the deployed tag is bumped from the build pipeline instead of from a
registry-triggered function.

## How it works

1. Mints an installation token for the `waffle-image-update` App, scoped to this
   repository.
2. Checks this repository out.
3. Runs `kustomize edit set image <image>:<tag>` in the given overlay directory,
   then rebuilds to confirm the new reference is rendered (see Validation).
4. Commits as `build: update <overlay-path without argocd/> to <tag>` and pushes
   to `main`. On a rejected push it resets onto the remote tip, re-applies the
   edit, and retries, up to five attempts.

Argo CD renders each overlay with kustomize and syncs the new tag.

`kustomize` and `yq` are preinstalled on GitHub's `ubuntu-24.04` runner images,
so the action does not install them.

## Inputs

| Input | Description |
| --- | --- |
| `image` | Image repository without tag, e.g. `yny.ocir.io/ax1dvc8vmenm/snutt-dev/snutt-timetable`. Must match a container image rendered by the overlay. |
| `tag` | New image tag to set. |
| `overlay-path` | Path to the kustomize directory, e.g. `argocd/snutt-dev/snutt-timetable`. |
| `private-key` | Private key (PEM) of the `waffle-image-update` App. |

All are required. The action has no outputs.

## Validation

`kustomize edit set image` appends a new entry to `images:` when the given name
matches nothing in the overlay, rather than failing. Left unchecked, a typo in
`image` or a wrong `overlay-path` produces a green workflow run and a commit that
deploys nothing, while the previous tag stays live.

After editing, the action rebuilds the overlay and requires `image:tag` to appear
as a rendered container image. The rendered output is read as YAML rather than
matched as text, so an `image:` inside a string value, such as a manifest
embedded in a ConfigMap, is not mistaken for a container image. If no container
matches, the run fails and lists the images the overlay does render.

The edit is re-applied from the current remote tip on every push attempt, so a
concurrent update to another overlay cannot revert this one.

Re-running a workflow run sets that run's tag again. Re-running the latest run is
a no-op; re-running an older one moves the overlay back to the older tag.

## Usage

```yaml
- name: Update GitOps image tag
  uses: wafflestudio/waffle-world-oci/.github/actions/update-image@main
  with:
    image: yny.ocir.io/ax1dvc8vmenm/snutt-dev/snutt-timetable
    tag: ${{ github.run_number }}
    overlay-path: argocd/snutt-dev/snutt-timetable
    private-key: ${{ secrets.DEPLOYER_APP_PRIVATE_KEY }}
```

The App must be installed on this repository with `contents: write`. Its App id
is not a secret and is set in `action.yml`; callers only supply the private key.
