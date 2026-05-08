return require("telescope").register_extension({
  exports = {
    parley_discussions = function(opts)
      return require("parley.telescope").discussions(opts)
    end,
  },
})
