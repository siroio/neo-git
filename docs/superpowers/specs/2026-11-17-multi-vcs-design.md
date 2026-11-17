# Multi-VCS support

The user approved the common UI / VCS-specific operations approach and requested implementation for jj, Mercurial, SVN and Perforce while preserving existing Git features. This document records implementation choices under that authorization.

## Scope and constraints

- Work only in `neo-git/`. No commits, installs into user configuration, changes to sibling packages or existing services.
- Emacs 29.1+, standard Elisp libraries, asynchronous argument-vector CLI calls.
- Keep all existing Git commands, keys, partial staging, caches, graph, editor integration and single-file Git installation working.
- Add `neo-vcs-status` as a universal entry point. `neo-git-status` also dispatches to installed non-Git support; explicit Git selection remains available, including colocated jj/Git repositories.
- Preserve the three-pane layout, diff highlighting, keyboard navigation and cleanup behavior. Each backend supplies its own actions; no synthetic Git index for other VCSs.
- Implement status, file diff, history, revision diff and ordinary changes: jj new/describe/split/squash/bookmarks/fetch/push/restore; hg add/remove/revert/commit/update/bookmark/merge/pull/push; SVN add/delete/revert/commit/update/switch/resolve; p4 edit/add/delete/reconcile/revert/change/reopen/submit/sync/shelve/unshelve/resolve.
- First release exposes whole-file selections for new backends. Existing Git line/hunk staging remains unchanged. CLI-driven interactive conflict editors, full depot administration and arbitrary history-rewrite interfaces are not part of this UI.

## Approach

Keep the mature Git workflow as the Git implementation. Share its asynchronous process primitive, layout and diff decoration with a capability-driven UI for the four new implementations. This avoids translating Git's index workflow into incompatible models and avoids a wholesale rewrite of the existing Git commands.

Alternatives considered: implementing every VCS through Git-shaped operations would lose required semantics; independent full UI copies would duplicate navigation and process cleanup. The approved common UI / backend design retains native semantics.

## Files

- `neo-git.el`: existing Git functionality, small generic process/layout extraction, entry-point dispatch.
- `neo-vcs.el`: backend registry, detection, sequential requests, status/history/diff panes, selection, action/message UI, lifecycle and protections.
- `neo-vcs-{jj,hg,svn,p4}.el`: CLI requests, output parsers and native action declarations.
- `check-vcs*.el`: ERT parser, request, lifecycle and isolated integration checks.
- README: install all files, CLI requirements, supported operation table and limits.

## Backend contract

`(neo-vcs-register-backend SYMBOL :program STRING :request FUNCTION :actions LIST :environment LIST)` registers a backend. Environment entries are `NAME=value` strings appended before the inherited environment. Never record passwords or tickets.

`(neo-vcs-BACKEND-request CONTEXT OPERATION &optional TARGET OPTIONS)` returns a request plist:

- `:commands`: ordered list of `(:args (STRING...) :stdin OPTIONAL-STRING :ok OPTIONAL-LIST-OF-EXIT-CODES :check OPTIONAL-FUNCTION)`; no shell. Global flags belong in each command. Default success is exit 0. Sequences stop at the first failure. `:check` receives successful stdout before the next command; a signalled error aborts the sequence, permitting native precondition checks.
- `:parse`: optional function called with the list of stdout strings in command order. Returns parsed data or signals an error for malformed output / protocol-level errors.

Successful stderr is retained separately from stdout, in command order. Mutation results show these diagnostics instead of claiming a silent success; JSON/XML parsers never receive the diagnostic stream. Native nonzero statuses stay failures (including Mercurial's exit 1 no-op push).

Context is `(:backend SYMBOL :root ABSOLUTE-DIRECTORY ...)`. Root discovery receives the initial directory in `:root` and returns a validated context with canonical trailing-slash root, optional `:label` and identity `:id`. Perforce adds its server/client identity. Core captures the inherited environment per session.

Operations and return types:

- `root`: context.
- `status`: `(:label STRING :entries (ENTRY...) :revision OPTIONAL-STRING)`. ENTRY contains `:path` relative to root, `:status` one of modified/added/deleted/missing/untracked/conflict/clean, optional `:group` string, optional `:old-path` and backend-specific metadata. Do not trust paths from CLI without containment checking. SVN can explicitly return `:root-entry t :path "."` for root properties/conflicts; this permits reading and browsing only, not generic file mutations.
- `history`: list of `(:id STRING :short STRING :author STRING :date STRING :subject STRING ...)` newest first.
- `diff`: TARGET is one ENTRY; returns unified diff string.
- `show`: TARGET is one history record; returns revision diff string.
- action id: TARGET is selected ENTRY list for file actions, one history record for revision actions, nil otherwise. OPTIONS carries `:message`, `:revision`, `:name`, `:change` or `:url` from the action prompt. Return data is an optional operation result string.

Action declarations: `(:id SYMBOL :key STRING :label STRING :target files|file|revision|nil :input message|revision|name|change|url|nil :destructive BOOL :worktree BOOL :confirm BOOL :capture-revision BOOL)`. All actions are mutations. `message` opens a multiline editor; `:capture-revision t` pins the status revision in the editor's options. File actions require a nonempty selection; `file` prompts for one existing regular file, using status metadata when available. Destructive/remote-submit actions receive an explicit confirmation showing backend, root and selection. Backend request builders must reject unsupported combinations instead of broadening the target. Keys reserved by the common pane (including a/x/r/R) cannot be assigned to backend actions.

Shared helpers: `neo-vcs--json TEXT` returns symbol-key alists and list arrays; `neo-vcs--paths CONTEXT ENTRIES` validates and returns root-relative paths; `neo-vcs--path CONTEXT PATH` validates one path. Parsers must preserve spaces, Unicode, newlines and literal metacharacters where the backend protocol supports them. Reject unsupported ambiguous representations explicitly.

## Lifecycle and safety

Requests have a session generation and a cancellation token. Superseded responses cannot replace newer displays. Refresh failure clears stale status/history/diff. Status and history queries are bounded; output overflow is an error, not a partial parse. Reads may be cancelled; mutation sequences hold the session open until all commands/callbacks complete. Closing an auxiliary pane cannot terminate a mutation. Writes are serialized, invalidate pending reads, reject unsaved buffers under the root, and reload only unmodified buffers afterward. Failed operations display stderr and command context.

Backend detection walks nearest ancestors, jj before Git when colocated. Explicit backend choice is available with a prefix argument. Perforce uses configured P4CONFIG/P4CLIENT or explicit selection and validates its workspace through the CLI; never scans unrelated depots. No implicit login or service creation in product flows.

Perforce uses UTF-8 command input/output. Non-ASCII operands require a Unicode server, detected from info; all file operands in such a command use one UTF-8 `-x -` stream to avoid Windows argv conversion and repeated fixed operands across batches. CR/LF in streamed filenames and non-ASCII form input to a non-Unicode server are rejected. Non-ASCII workspace/client/user identifiers remain outside the live-tested coverage. The CLI's irreversible non-UTF8 JSON replacements are errors, never guessed paths.

## Verification

Run the existing Git checks and new ERT checks with temporary files, Emacs state and test repositories inside `neo-git/var/`. Exercise installed jj and SVN against real isolated repositories. Use protocol fixtures and request tests for missing CLIs, and report these separately from real integration tests. Any test-only downloaded tools or ephemeral p4 server must remain under `var/`; do not change PATH or a shared server. Review final diffs and test evidence before completion.
