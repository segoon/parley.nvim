--- Test fixture construction for shared remote and local review state.
--- @param M table
--- @param register_bufnr function
--- @param build_summary function
return function(M, register_bufnr, build_summary)
  --- Seed both shared and per-file data from a single composite snapshot.
  --- @param bufnr integer
  --- @param snapshot table|nil  same shape as the old _entries[bufnr]
  --- @param review_key? string  defaults to "test/repository/branch"
  return function(bufnr, snapshot, review_key)
    review_key = review_key or "test/repository/branch"
    register_bufnr(bufnr, review_key)
    if not snapshot then
      M._reviews[review_key] = nil
      M._views[bufnr] = nil
      return
    end
    M._reviews[review_key] = {
      status = snapshot.status or "ready",
      stale = snapshot.stale or false,
      review = snapshot.review,
      pr = snapshot.pr or (snapshot.review and snapshot.review.pr or nil),
      all_discussions = snapshot.all_discussions or {},
      summary = snapshot.summary or build_summary(snapshot.all_discussions or {}),
      error = snapshot.error,
      head_sha = snapshot.head_sha or "",
    }
    M._views[bufnr] = {
      discussions = snapshot.discussions or {},
      mappings = snapshot.mappings or {},
      all_mappings = snapshot.all_mappings or snapshot.mappings or {},
    }
  end
end
