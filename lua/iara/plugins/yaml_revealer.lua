-- yaml-revealer shows the current YAML key path as virtual text.
-- iara.features.structured.yaml_legacy owns its handlers, mapping, and
-- namespace, and suspends them in conservative buffers.
return {
  "Einenlum/yaml-revealer",
  ft = "yaml",
  -- An own `cond` replaces Iara's default one, so it is called here.
  cond = function(plugin)
    return require("iara.core.lazy").available(plugin)
      and require("iara.config").enabled("features.structured")
  end,
  config = function()
    local config = require("iara.config").get()
    require("iara.features.structured.yaml_legacy").setup(config)
  end,
}
