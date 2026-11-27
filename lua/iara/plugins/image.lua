-- Load on demand for graphical PDFs. Users can override the image options.
return {
  "3rd/image.nvim",
  lazy = true,
  main = "image",
  opts = function()
    return require("iara.features.pdf.graphics").options()
  end,
}
