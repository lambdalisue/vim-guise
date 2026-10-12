-- Health check of guise for Neovim (:checkhealth guise).
--
-- The checks live in autoload/guise/health.vim so that ":GuiseCheck" on Vim
-- reports the same.

local M = {}

function M.check()
  for _, section in ipairs(vim.fn["guise#health#check"]()) do
    vim.health.start(section.name)
    for _, result in ipairs(section.results) do
      local advice = result.advice ~= "" and result.advice or nil
      vim.health[result.level](result.msg, advice)
    end
  end
end

return M
