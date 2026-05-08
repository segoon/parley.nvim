- github provider
- arcanum provider
- diffview.nvim integration
- discussion view
- discussion edits (new comment / add reaction / etc.)
- statusline
- checkhealth
- README.md
- vim help
- vim help for providers (auto generate?)
- default keymapping
- :Telescope discussions|issues|comments? vcs_issues?
- mark comment as stale (outdated position)
- ]c, [c for the discussion buffer

UI:
- virtual lines below the commented line, not right to it
- configure comment preview layout in setup(...)

Bugs:
- background update failure should be silent
- too many asserts - detect_pr() must be called before
- input window must be a buffer just under discussion buffer (split)
