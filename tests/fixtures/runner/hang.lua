local T = MiniTest.new_set()

T["never returns"] = function()
  vim.wait(60000, function()
    return false
  end)
end

return T
