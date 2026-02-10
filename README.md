# docforge
<!-- coverage-badges:start -->
![Doc Coverage](https://img.shields.io/badge/doc%20coverage-100%25-brightgreen)
![Test Coverage](https://img.shields.io/badge/test%20coverage-100%25-brightgreen)
<!-- coverage-badges:end -->

Generate static API docs for many repositories and publish them under a single GitHub Pages path.

## What it does
- Accepts local paths, git SSH/HTTPS URLs, and archive URLs
- Supports version/tag/commit references (auto-infers when omitted)
- Auto-detects doc tool when not specified
- Emits docs into a GitHub Pages-friendly folder layout
- Generates a global index page with repo metadata and search links
- Injects a floating Docs index button into generated HTML
- Deploys the site output to a gh-pages branch
- Designed to run on Windows, Linux, and macOS

## Requirements
- Zig (0.11+ recommended)
- Git installed and on PATH
- One or more doc generators (mkdocs, sphinx, doxygen, go, cargo)
- For archive URLs: curl + tar/unzip on macOS/Linux, PowerShell + tar/Expand-Archive on Windows

## Quick start
1) Create a config:
```
zig build run -- init --username yourname --path docs --output-dir site
```
2) Edit `docforge.json` to add repos.
3) Generate docs:
```
zig build run -- run --config docforge.json
```
Use `--no-incremental` to force rebuilding all docs.

4) Deploy to GitHub Pages:
```
zig build run -- deploy --config docforge.json
```

## Repo discovery
Generate a config by scanning a root folder for git repos:
```
zig build run -- discover --root /path/to/repos --config docforge.json
```

Options:
- `--depth N` limits recursion depth (default 6)
- `--username`, `--path`, `--output-dir` set GitHub Pages layout
- `--absolute` stores absolute repo paths instead of relative
- `--no-infer-tool` skips doc tool inference during discovery

## CLI
Common commands:
- `run` generates docs from the config
- `list` prints configured repos, detected tools, and last commit (from manifests)
- `clean` removes `.docforge/cache`, `.docforge/work`, and the site output path
- `deploy` publishes to GitHub Pages

Useful flags:
- `--json` emits JSON log lines (including command logs when `--verbose` is set)
- `--insecure` skips SSL verification for git and curl
- `--preserve-history` keeps existing `gh-pages` content and adds new commits on top

## Config format (docforge.json)
```
{
  "site": {
    "username": "yourname",
    "path": "docs",
    "output_dir": "site"
  },
  "tool_templates": {
    "mkdocs": { "argv": ["mkdocs", "build", "--clean", "-d", "{output_dir}"] },
    "sphinx": { "argv": ["sphinx-build", "-b", "html", "{doc_abs}", "{output_dir}"] },
    "doxygen": { "argv": ["doxygen", "{config_path}"] },
    "cargo": { "argv": ["cargo", "doc", "--no-deps", "--target-dir", "{output_dir}"] }
  },
  "index_template": "index-template.html",
  "cache_dir": ".docforge/cache",
  "work_dir": ".docforge/work",
  "repos": [
    {
      "name": "repo-name",
      "source": "../path/to/repo",
      "ref": { "kind": "tag", "value": "v1.2.3" },
      "doc_tool": "mkdocs",
      "doc_path": "docs",
      "output_subpath": "repo-name"
    }
  ]
}
```

### Repo options
Additional repo fields:
- `include` / `exclude`: glob patterns to filter the working tree before docs are generated
- `pre_build` / `post_build`: arrays of command argv arrays to run before/after doc generation
- `argv`: command argv to run when `doc_tool` is set to `shell`
- `shallow`: `true` to clone/fetch with depth 1 for large git repos

Example hooks:
```
"pre_build": [["npm", "install"], ["npm", "run", "build"]],
"post_build": [["npm", "run", "lint"]]
```

### Ref kinds
- `version`: treated like a tag (semantic version)
- `tag`: explicit git tag
- `commit`: explicit git commit hash

If `ref` is omitted, the tool checks out `HEAD` and infers a tag or commit hash for reporting.

### Doc tool inference
- `mkdocs` if `mkdocs.yml` or `mkdocs.yaml` exists
- `sphinx` if `docs/conf.py` or `conf.py` exists
- `doxygen` if `Doxyfile` exists
- `godoc` if `go.mod` exists
- `cargo` if `Cargo.toml` exists

You can always set `doc_tool` explicitly to override.

### Env var expansion
`source` strings support `${VAR}` substitution for CI/CD secrets (for example, private Git URLs).

### Shell tool
Set `doc_tool` to `shell` and provide `argv` to run a custom generator. The argv list accepts the same `{repo_path}`, `{output_dir}`, `{doc_path}`, `{doc_abs}`, and `{config_path}` placeholders as templates.

## Output layout
Docs are written to:
```
<output_dir>/<path>/<repo-subpath>/
```

The global index is written to:
```
<output_dir>/<path>/index.html
```

If you set `username=yourname` and `path=docs`, publish the `site` folder to `yourname.github.io` and your docs will be available at:
```
https://yourname.github.io/docs/<repo-subpath>/
```

## Custom index template
Set `index_template` to point at a custom HTML file. The template must include `{{entries}}` where the repo table should render. Optional tokens:
- `{{site_username}}`
- `{{site_path}}`
- `{{site_url}}`

## Tool templates
You can override the command used for each doc tool by setting `tool_templates`. Templates accept these placeholders:
- `{repo_path}`: repository root
- `{output_dir}`: output directory
- `{doc_path}`: resolved doc path (relative)
- `{doc_abs}`: resolved doc path (absolute)
- `{config_path}`: generated Doxygen config path

Changing a tool template forces a rebuild for repos that use that tool.

## Deploy
Publish the generated site to the `gh-pages` branch of the current repo:
```
zig build run -- deploy --config docforge.json
```
Use `--remote`, `--branch`, and `--message` to customize the target. Add `--preserve-history` to keep existing `gh-pages` content and append new commits.

## Testing
Run:
```
zig build test
```

Project policy: 100% doc coverage for public APIs and 100% test coverage for core logic.

## Notes
- Worktrees are created under `.docforge/work` and are safe to delete.
- Cached clones and downloads live under `.docforge/cache`.
