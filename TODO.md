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
- mark comment as stale (outdated position)

documentation:
- test on 'all commands/options/highlights are covered'
- test on valid references

Bugs:
- multiple buffers with different repositories
- no autocompletion on :'<,'>
- tests isolation (pending callbacks, subscriptions)
