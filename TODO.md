features:
- :Telescope discussions|issues|comments? vcs_issues? - preview
- multiple discussions of the same line
- resolve/unresolve thread, unresolved count (GraphQL)

features (2):
- X-RateLimit-*, 429, 403 from gh
- arcanum provider
- diffview.nvim integration
- consistent opts for setup()

quality:
- lua-language-server type warnings, but not in linter

UI:
- configure comment preview layout in setup(...)
- mark comment as stale (outdated position)

Bugs:
- multiple buffers with different repositories
- cannot edit my own comment
