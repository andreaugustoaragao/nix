---
name: new-repo
description: Prepare a requested Git repository backup or remote publication using the named host, existing git state, and available provider tools.
---

# Create or publish a repository

Inspect current repository status, branch, remotes, staged content, untracked files, ignore rules, and the user's requested destination. An existing remote does not forbid a second explicitly requested destination. Preserve existing remotes and unrelated work. Avoid printing credential-bearing remote URLs.

A repository is hosted by the selected Git provider; PI and Codex are clients. Do not advertise a host belonging to another product as Codex hosting. Infer the host only from clear session context; a material missing destination needs clarification.

For a new local repository, initialize using the project's requested branch convention. Stage named intended files or hunks after checking for credentials and generated dependencies. Do not stage everything or assume `main`. A backup commit includes only authorized content; keep untracked user files intact.

For remote creation, use an available authenticated provider tool or the provider's documented API only when creation, owner, name, and visibility are authorized. Respect repository restrictions on tools. If creation/authentication is unavailable, finish local preparation and report the missing capability; do not install an unrelated CLI, guess a URL, or claim a remote exists.

Add the authorized remote without overwriting another destination. Push the actual intended branch/commit only when publication is requested. Verify the remote ref equals the pushed commit before reporting success. Provide a real provider URL only when obtained from provider evidence. Explain local commit, remote backup, and public sharing separately; do not imply a local save made content public.

System tooling is Nix-managed on this machine. Do not use global imperative installers or expose tokens in commands/logs.
