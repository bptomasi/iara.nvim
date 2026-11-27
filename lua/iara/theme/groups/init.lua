--- Highlight groups of every Iara theme, one module per screen so later
--- tasks own disjoint files (design 09, section 5). Each module returns
--- `{ [group] = spec }`; this one merges them with the role groups of
--- `iara.theme.roles` into one table for `iara.theme.highlights`.
---
--- Color values name a palette slot: a `base_30` name ("blue",
--- "darker_black") or a `base_16` name ("base0D"); a role ("@accent",
--- "@muted", see `iara.theme.roles`); "#rrggbb" and "NONE" pass through.
--- A table `{ top, bottom, percent }` blends two of them (`top` over
--- `bottom` at `percent` opacity). No group is defined by two modules.

---Group modules under `iara.theme.groups`, merged in this order.
local MODULES = {
  "editor",
  "syntax",
  "floats",
  "status",
  "progress",
  "search",
  "start",
  "panels",
  "explorer",
  "health",
  "plugins",
  "ai",
  "markdown",
}

local groups = {}
for _, name in ipairs(MODULES) do
  for group, spec in pairs(require("iara.theme.groups." .. name)) do
    groups[group] = spec
  end
end
for group, spec in pairs(require("iara.theme.roles").GROUPS) do
  groups[group] = spec
end

return groups
