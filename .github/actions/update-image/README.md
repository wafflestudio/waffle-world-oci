# update-image action

Updates a kustomize overlay's image tag in this GitOps repository and pushes the
commit. Service repositories call it after building and pushing an image to
OCIR, so the deployed tag is bumped from the build pipeline instead of from a
registry-triggered function.

## How it works

1. Mints an installation token from the given GitHub App (`app-id` +
   `private-key`), scoped to the GitOps repository. A pre-issued `token` can be
   passed instead.
2. Checks out the GitOps repository (`wafflestudio/waffle-world-oci` by default).
3. Builds the overlay and checks that it renders a container using `image`,
   failing if it does not (see Validation below).
4. Runs `kustomize edit set image <image>:<tag>` in the given overlay directory,
   which updates the `newTag` field in that overlay's `kustomization.yaml`, then
   rebuilds to confirm the new reference is actually rendered.
5. Commits the change as `build: update <overlay-path without argocd/> to <tag>`
   and pushes to the target branch. On a rejected push it resets onto the remote
   tip, re-applies the edit, and retries.

Argo CD renders each overlay with kustomize and syncs the new tag.

## Validation

`kustomize edit set image` appends a new entry to `images:` when the given name
matches nothing in the overlay, rather than failing. Left unchecked, a typo in
`image` or a wrong `overlay-path` produces a green workflow run and a commit that
deploys nothing, while the previous tag stays live.

After editing, the action rebuilds the overlay and requires `image:tag` to appear
as a rendered container image. If it does not, the run fails and lists the images
the overlay does render.

The edit is re-applied from the current remote tip on every push attempt, so a
concurrent update to another overlay cannot revert this one.

Re-running a workflow run sets that run's tag again. Re-running the latest run is
a no-op; re-running an older one moves the overlay back to the older tag.

## Authentication

Pass **either** a GitHub App (`app-id` + `private-key`) **or** a pre-issued
`token`. With the App path, the action generates a short-lived installation
token itself (scoped to the GitOps repo), so the caller does not run
`create-github-app-token` separately, and the commit is attributed to the App's
bot identity automatically. The App must be installed on the GitOps repository
with `contents: write`.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `image` | yes | | Image repository without tag, e.g. `yny.ocir.io/ax1dvc8vmenm/snutt-dev/snutt-timetable`. Must match the `images[].name` in the overlay's `kustomization.yaml`. |
| `tag` | yes | | New image tag to set. |
| `overlay-path` | yes | | Path to the kustomize directory, e.g. `argocd/snutt-dev/snutt-timetable`. |
| `app-id` | one of | | GitHub App ID. With `private-key`, the action mints the token itself. |
| `private-key` | one of | | GitHub App private key (PEM). Required when `app-id` is set. |
| `token` | one of | | Pre-issued token with write access to the GitOps repo (e.g. a PAT). Alternative to `app-id`/`private-key`. |
| `gitops-repository` | no | `wafflestudio/waffle-world-oci` | Repository to update. |
| `gitops-branch` | no | `main` | Branch to commit to. |
| `committer-name` | no | App bot, else `github-actions[bot]` | git `user.name` for the commit. |
| `committer-email` | no | App bot, else `github-actions[bot]` | git `user.email` for the commit. |
| `kustomize-version` | no | `5.8.1` | kustomize version to install and run. |

Provide exactly one of `app-id`+`private-key` or `token`.

## Outputs

| Output | Description |
| --- | --- |
| `image` | Full image reference that was set (`image:tag`). |
| `commit-sha` | SHA of the pushed commit, empty if the tag was already up to date. |

## Usage

```yaml
- name: Update GitOps image tag
  uses: wafflestudio/waffle-world-oci/.github/actions/update-image@main
  with:
    image: yny.ocir.io/ax1dvc8vmenm/snutt-dev/snutt-timetable
    tag: ${{ github.run_number }}
    overlay-path: argocd/snutt-dev/snutt-timetable
    app-id: ${{ secrets.DEPLOYER_APP_ID }}
    private-key: ${{ secrets.DEPLOYER_APP_PRIVATE_KEY }}
```
