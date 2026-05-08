return require("telescope").register_extension({
  exports = {
    parley_discussions_file = function(opts)
      return require("parley.telescope").discussions_file(opts)
    end,
  },
})
