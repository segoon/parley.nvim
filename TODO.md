features:
- :Telescope discussions|issues|comments? vcs_issues? - preview
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
- cancelling new discussion => empty discussion window, weird
- (no comments in the discussion yet) text
- 'stale anchor' verbatim

documentation:
- test on 'all commands/options/highlights are covered'
- test on valid references

tests:
- tests isolation (pending callbacks, subscriptions)
- dependency restrictions: source directory
