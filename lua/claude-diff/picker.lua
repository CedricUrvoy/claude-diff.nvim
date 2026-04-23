local M = {}
local session = require("claude-diff.session")
local diff    = require("claude-diff.diff")

function M.pick()
  local manifest = session.read_manifest()
  local files    = vim.tbl_keys(manifest)

  if #files == 0 then
    vim.notify("No files changed in current Claude session", vim.log.levels.INFO)
    return
  end

  table.sort(files)
  diff.set_files(files, 1)

  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.fn.setqflist({}, "r", {
      title = "Claude session changes",
      items = vim.tbl_map(function(f)
        return { filename = f, text = "Claude modified" }
      end, files),
    })
    vim.cmd("copen")
    return
  end

  snacks.picker({
    title  = "Claude session changes",
    items  = vim.tbl_map(function(f)
      local label = manifest[f] and manifest[f].new and "[new] " or ""
      return { text = label .. vim.fn.fnamemodify(f, ":~:."), file = f }
    end, files),
    format  = "text",
    confirm = function(picker, item)
      picker:close()
      if item then
        local idx = vim.fn.index(files, item.file) + 1
        diff.set_files(files, idx)
        diff.open_diff_for_file(item.file)
      end
    end,
    preview = function(ctx)
      local item = ctx.item
      if not item then return end
      local original = session.get_original(item.file)
      if not original then return end
      local current  = table.concat(vim.fn.readfile(item.file), "\n")
      local patch    = vim.diff(original, current, { result_type = "unified", ctxlen = 3 })
      ctx.preview:set_lines(vim.split(patch or "(no diff)", "\n"))
      ctx.preview:highlight({ ft = "diff" })
      ctx.preview:wo({ foldenable = false })
    end,
  })
end

return M
