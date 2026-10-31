# OmniRoute in GitHub Codespaces

## Runtime behavior

- The devcontainer starts OmniRoute after the container starts and checks again
  whenever the workspace is attached.
- Startup is serialized with `flock` so lifecycle hooks cannot launch duplicate
  Next.js processes.
- A start is successful only when `/healthz` returns HTTP 200. The login page
  alone is not treated as proof that the application is ready.
- The startup hook allows up to four minutes for a cold start, records output
  in `.logs/omniroute.log`, and preserves logs when startup fails.
- The development Node.js heap is capped at 4 GiB to leave memory for the
  Codespaces container, editor, and native tooling.
- SWC uses a private cache in the Codespaces user's home directory.

## Manual diagnostics

From the repository root:

```bash
bash -n .devcontainer/start-omniroute.sh
bash .devcontainer/start-omniroute.sh
curl -i http://127.0.0.1:20128/healthz
tail -n 100 .logs/omniroute.log
```

The startup hook does not read, print, or modify environment files or secrets.

## Important lifecycle limitation

GitHub Codespaces may stop or suspend a workspace because of its idle timeout,
maximum lifetime, or account quota. A devcontainer hook cannot override those
platform controls. This configuration improves startup after a container
start/reattach; it does not turn Codespaces into an always-on production host.
For a persistent gateway, use the documented self-host Docker deployment on an
always-on machine with persistent storage and authenticated ingress.
