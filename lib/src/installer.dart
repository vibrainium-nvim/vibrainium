import 'dart:io';

import 'package:nvim/nvim.dart';

import 'daemon.dart';

/// Installs and uninstalls the `vibrainium` Neovim plugin into Neovim's
/// `site` directory (`plugin/vibrainium.lua` and `lua/vibrainium/init.lua`)
/// without using symlinks, compatible with both vanilla Neovim and `lazy.nvim`.
class VibrainiumInstaller {
  static String defaultSiteDir() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final localAppData = env['LOCALAPPDATA'] ?? '${env['USERPROFILE']}\\AppData\\Local';
      return '$localAppData\\nvim-data\\site';
    }
    final xdgDataHome = env['XDG_DATA_HOME'];
    if (xdgDataHome != null && xdgDataHome.isNotEmpty) {
      return '$xdgDataHome/nvim/site';
    }
    final home = env['HOME'] ?? '';
    return '$home/.local/share/nvim/site';
  }

  /// Resolves a `--dev <path>` argument to the `vibrainium` package directory
  /// containing `bin/vibrainium.dart`.
  static String resolveDevPackagePath(String rawPath) {
    final abs = Directory(rawPath).absolute.path;
    final clean = abs.endsWith(Platform.pathSeparator)
        ? abs.substring(0, abs.length - 1)
        : abs;
    if (File('$clean/bin/vibrainium.dart').existsSync()) {
      return clean;
    }
    if (File('$clean/vibrainium/bin/vibrainium.dart').existsSync()) {
      return '$clean/vibrainium';
    }
    throw ArgumentError(
      'Could not find bin/vibrainium.dart under "$rawPath" (checked "$clean/bin/vibrainium.dart" and "$clean/vibrainium/bin/vibrainium.dart").',
    );
  }

  static Future<void> _deleteEntityIfExists(String path) async {
    final existingType = await FileSystemEntity.type(path, followLinks: false);
    if (existingType == FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (existingType == FileSystemEntityType.file) {
      await File(path).delete();
    } else if (existingType == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    }
  }

  /// Writes `plugin/vibrainium.lua` and `lua/vibrainium/init.lua` into
  /// `<siteDir>`.
  ///
  /// - If [devPath] is null, the installed Lua plugin spawns `vibrainium` from system `PATH`.
  /// - If [devPath] is provided, the installed Lua plugin spawns `dart run <devPkg>/bin/vibrainium.dart --dev <devPkg>`.
  static Future<String> install({
    String? devPath,
    String? siteDir,
  }) async {
    final base = siteDir ?? defaultSiteDir();
    final targetRoot = Directory(base);
    final pluginFile = File('${targetRoot.path}/plugin/vibrainium.lua');
    final luaDir = Directory('${targetRoot.path}/lua/vibrainium');
    final legacyPackDir = Directory('${targetRoot.path}/pack/vibrainium');

    // Remove any existing installation or stale symlink/legacy pack directory first
    await _deleteEntityIfExists(pluginFile.path);
    await _deleteEntityIfExists(luaDir.path);
    await _deleteEntityIfExists(legacyPackDir.path);

    await pluginFile.parent.create(recursive: true);
    await luaDir.create(recursive: true);

    String? resolvedDevPkg;
    if (devPath != null) {
      resolvedDevPkg = resolveDevPackagePath(devPath);
    }

    final socketPath = VibrainiumDaemon.defaultSocketPath(
      devPackagePath: resolvedDevPkg,
    );
    await VibrainiumDaemon.stopRunningDaemon(socketPath);

    await pluginFile.writeAsString(
      _generatePluginLua(),
    );
    await File('${luaDir.path}/init.lua').writeAsString(
      _generateInitLua(
        socketPath: socketPath,
        devPackagePath: resolvedDevPkg,
      ),
    );

    return targetRoot.path;
  }

  /// Removes installed `vibrainium` files from `<siteDir>`.
  static Future<bool> uninstall({String? siteDir}) async {
    await VibrainiumDaemon.stopRunningDaemon(
      VibrainiumDaemon.defaultSocketPath(),
    );
    final base = siteDir ?? defaultSiteDir();
    final pluginFile = File('$base/plugin/vibrainium.lua');
    final luaDir = Directory('$base/lua/vibrainium');
    final legacyPackDir = Directory('$base/pack/vibrainium');

    var removed = false;
    for (final path in [pluginFile.path, luaDir.path, legacyPackDir.path]) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        await _deleteEntityIfExists(path);
        removed = true;
      }
    }
    return removed;
  }

  static String _generatePluginLua() {
    return '''
if vim.g.loaded_vibrainium == 1 then
  return
end
vim.g.loaded_vibrainium = 1

local subcommands = {
  ['vcs.open'] = function() require('vibrainium').open() end,
  ['vcs.toggle'] = function() require('vibrainium').toggle() end,
  ['vcs.close'] = function() require('vibrainium').close() end,
  ['vcs.refresh'] = function() require('vibrainium').refresh() end,
  ['vcs.repopicker'] = function() require('vibrainium').repo_picker() end,
  ['vcs.repo_picker'] = function() require('vibrainium').repo_picker() end,
  ['workspace.open'] = function() require('vibrainium').workspace_open() end,
  ['workspace.toggle'] = function() require('vibrainium').workspace_toggle() end,
  ['workspace.close'] = function() require('vibrainium').workspace_close() end,
  ['workspace.refresh'] = function() require('vibrainium').workspace_refresh() end,
  ['workspace.reveal'] = function() require('vibrainium').workspace_reveal() end,
  ['problems.open'] = function() require('vibrainium').problems_open() end,
  ['problems.toggle'] = function() require('vibrainium').problems_toggle() end,
  ['problems.close'] = function() require('vibrainium').problems_close() end,
  ['problems.refresh'] = function() require('vibrainium').problems_refresh() end,
  ['agents.open'] = function() require('vibrainium').agents_open() end,
  ['agents.toggle'] = function() require('vibrainium').agents_toggle() end,
  ['agents.close'] = function() require('vibrainium').agents_close() end,
  ['agents.refresh'] = function() require('vibrainium').agents_refresh() end,
  ['agents.newantigravity'] = function() require('vibrainium').agent_new_antigravity() end,
  ['agents.new_antigravity'] = function() require('vibrainium').agent_new_antigravity() end,
  ['agents.newclaude'] = function() require('vibrainium').agent_new_claude() end,
  ['agents.new_claude'] = function() require('vibrainium').agent_new_claude() end,
  ['agents.sendselection'] = function() require('vibrainium').agent_send_selection() end,
  ['agents.send_selection'] = function() require('vibrainium').agent_send_selection() end,
  ['agents.sendselectionto'] = function() require('vibrainium').agent_send_selection_to() end,
  ['agents.send_selection_to'] = function() require('vibrainium').agent_send_selection_to() end,
  ['agents.sendfile'] = function() require('vibrainium').agent_send_file() end,
  ['agents.send_file'] = function() require('vibrainium').agent_send_file() end,
  ['search.files'] = function() require('vibrainium').files() end,
  ['search.text'] = function() require('vibrainium').grep() end,
  ['search.grep'] = function() require('vibrainium').grep() end,
  ['search.symbols'] = function() require('vibrainium').symbols() end,
  ['search.close'] = function() require('vibrainium').search_close() end,
  ['diff.togglemode'] = function() require('vibrainium').diff_toggle_mode() end,
  ['diff.toggle_mode'] = function() require('vibrainium').diff_toggle_mode() end,
  ['diff.copyreview'] = function() require('vibrainium').diff_copy_review() end,
  ['diff.copy_review'] = function() require('vibrainium').diff_copy_review() end,
  ['diff.close'] = function() require('vibrainium').diff_close() end,
  ['buffer.next'] = function() require('vibrainium').buffer_next() end,
  ['buffer.prev'] = function() require('vibrainium').buffer_prev() end,
  ['buffer.close'] = function() require('vibrainium').buffer_close() end,
  ['buffer.closeothers'] = function() require('vibrainium').buffer_close_others() end,
  ['buffer.close_others'] = function() require('vibrainium').buffer_close_others() end,
  ['buffer.closeright'] = function() require('vibrainium').buffer_close_right() end,
  ['buffer.close_right'] = function() require('vibrainium').buffer_close_right() end,
  ['buffer.closeall'] = function() require('vibrainium').buffer_close_all() end,
  ['buffer.close_all'] = function() require('vibrainium').buffer_close_all() end,
  ['buffer.copypath'] = function() require('vibrainium').buffer_copy_path() end,
  ['buffer.copy_path'] = function() require('vibrainium').buffer_copy_path() end,
  ['buffer.reveal'] = function() require('vibrainium').buffer_reveal() end,
  ['buffer.menu'] = function() require('vibrainium').buffer_menu() end,
  ['tab.next'] = function() require('vibrainium').tab_next() end,
  ['tab.prev'] = function() require('vibrainium').tab_prev() end,
  ['panel.toggleleft'] = function() require('vibrainium').left_panel_toggle() end,
  ['panel.toggle_left'] = function() require('vibrainium').left_panel_toggle() end,
  ['left_panel.toggle'] = function() require('vibrainium').left_panel_toggle() end,
  ['panel.togglebottom'] = function() require('vibrainium').bottom_panel_toggle() end,
  ['panel.toggle_bottom'] = function() require('vibrainium').bottom_panel_toggle() end,
  ['bottom_panel.toggle'] = function() require('vibrainium').bottom_panel_toggle() end,
  ['reload'] = function() require('vibrainium').reload() end,
}

local completions = {
  'Vcs.Open',
  'Vcs.Toggle',
  'Vcs.Close',
  'Vcs.Refresh',
  'Vcs.RepoPicker',
  'Workspace.Open',
  'Workspace.Toggle',
  'Workspace.Close',
  'Workspace.Refresh',
  'Workspace.Reveal',
  'Problems.Open',
  'Problems.Toggle',
  'Problems.Close',
  'Problems.Refresh',
  'Agents.Open',
  'Agents.Toggle',
  'Agents.Close',
  'Agents.Refresh',
  'Agents.NewAntigravity',
  'Agents.NewClaude',
  'Agents.SendSelection',
  'Agents.SendSelectionTo',
  'Agents.SendFile',
  'Search.Files',
  'Search.Text',
  'Search.Symbols',
  'Search.Close',
  'Diff.ToggleMode',
  'Diff.CopyReview',
  'Diff.Compare',
  'Diff.Close',
  'Buffer.Next',
  'Buffer.Prev',
  'Buffer.Close',
  'Buffer.CloseOthers',
  'Buffer.CloseRight',
  'Buffer.CloseAll',
  'Buffer.CopyPath',
  'Buffer.Reveal',
  'Buffer.Menu',
  'Tab.Next',
  'Tab.Prev',
  'Panel.ToggleLeft',
  'Panel.ToggleBottom',
  'Reload',
}

vim.api.nvim_create_user_command('Vibrainium', function(opts)
  if #opts.fargs >= 3 and opts.fargs[1]:lower() == 'diff.compare' then
    require('vibrainium').diff_compare(opts.fargs[2], opts.fargs[3])
    return
  end
  local key = table.concat(opts.fargs, '.'):lower()
  local fn = subcommands[key]
  if fn then
    fn()
  else
    vim.notify('[Vibrainium] Unknown subcommand: ' .. table.concat(opts.fargs, ' '), vim.log.levels.ERROR)
  end
end, {
  nargs = '+',
  complete = function(arg_lead)
    local matches = {}
    local lead_lower = arg_lead:lower()
    for _, item in ipairs(completions) do
      if item:lower():find(lead_lower, 1, true) == 1 then
        table.insert(matches, item)
      end
    end
    return matches
  end,
  desc = 'Vibrainium commands (e.g. :Vibrainium Vcs.Open, :Vibrainium Workspace.Open, :Vibrainium Reload)',
})

vim.api.nvim_create_user_command('VibrainiumVcsToggle', function()
  require('vibrainium').toggle()
end, { desc = 'Toggle the vivcs version control side panel' })

vim.api.nvim_create_user_command('VibrainiumVcsOpen', function()
  require('vibrainium').open()
end, { desc = 'Open the vivcs version control side panel' })

vim.api.nvim_create_user_command('VibrainiumVcsClose', function()
  require('vibrainium').close()
end, { desc = 'Close the vivcs version control side panel' })

vim.api.nvim_create_user_command('VibrainiumVcsRefresh', function()
  require('vibrainium').refresh()
end, { desc = 'Refresh the vivcs version control side panel' })

vim.api.nvim_create_user_command('VibrainiumVcsRepoPicker', function()
  require('vibrainium').repo_picker()
end, { desc = 'Open the vivcs repository dropdown picker' })

vim.api.nvim_create_user_command('VibrainiumWorkspaceToggle', function()
  require('vibrainium').workspace_toggle()
end, { desc = 'Toggle the viworkspace explorer side panel' })

vim.api.nvim_create_user_command('VibrainiumWorkspaceOpen', function()
  require('vibrainium').workspace_open()
end, { desc = 'Open the viworkspace explorer side panel' })

vim.api.nvim_create_user_command('VibrainiumWorkspaceClose', function()
  require('vibrainium').workspace_close()
end, { desc = 'Close the viworkspace explorer side panel' })

vim.api.nvim_create_user_command('VibrainiumWorkspaceRefresh', function()
  require('vibrainium').workspace_refresh()
end, { desc = 'Refresh the viworkspace explorer side panel' })

vim.api.nvim_create_user_command('VibrainiumWorkspaceReveal', function()
  require('vibrainium').workspace_reveal()
end, { desc = 'Reveal the active buffer file in the viworkspace explorer side panel' })

vim.api.nvim_create_user_command('VibrainiumProblemsToggle', function()
  require('vibrainium').problems_toggle()
end, { desc = 'Toggle the viproblems diagnostics bottom panel' })

vim.api.nvim_create_user_command('VibrainiumProblemsOpen', function()
  require('vibrainium').problems_open()
end, { desc = 'Open the viproblems diagnostics bottom panel' })

vim.api.nvim_create_user_command('VibrainiumProblemsClose', function()
  require('vibrainium').problems_close()
end, { desc = 'Close the viproblems diagnostics bottom panel' })

vim.api.nvim_create_user_command('VibrainiumProblemsRefresh', function()
  require('vibrainium').problems_refresh()
end, { desc = 'Refresh the viproblems diagnostics bottom panel' })

vim.api.nvim_create_user_command('VibrainiumAgentsToggle', function()
  require('vibrainium').agents_toggle()
end, { desc = 'Toggle the viagent AI agents bottom panel' })

vim.api.nvim_create_user_command('VibrainiumAgentsOpen', function()
  require('vibrainium').agents_open()
end, { desc = 'Open the viagent AI agents bottom panel' })

vim.api.nvim_create_user_command('VibrainiumAgentsClose', function()
  require('vibrainium').agents_close()
end, { desc = 'Close the viagent AI agents bottom panel' })

vim.api.nvim_create_user_command('VibrainiumLeftPanelToggle', function()
  require('vibrainium').left_panel_toggle()
end, { desc = 'Toggle the unified Vibrainium left side panel' })

vim.api.nvim_create_user_command('VibrainiumBottomPanelToggle', function()
  require('vibrainium').bottom_panel_toggle()
end, { desc = 'Toggle the unified Vibrainium bottom panel' })

vim.api.nvim_create_user_command('VibrainiumAgentSendSelection', function(opts)
  local name = vim.api.nvim_buf_get_name(0) or ''
  require('vibrainium').agent_send_selection(name, opts.line1, opts.line2)
end, { range = true, desc = 'Send compact @file#Lstart-Lend selection reference to the active AI agent chat' })

vim.api.nvim_create_user_command('VibrainiumAgentSendSelectionTo', function(opts)
  local name = vim.api.nvim_buf_get_name(0) or ''
  require('vibrainium').agent_send_selection_to(name, opts.line1, opts.line2)
end, { range = true, desc = 'Pick an AI agent chat and send @file#Lstart-Lend selection reference' })

vim.api.nvim_create_user_command('VibrainiumReload', function()
  require('vibrainium').reload()
end, { desc = 'Hot reload the vibrainium Dart VM isolate' })

vim.api.nvim_create_user_command('VibrainiumFiles', function()
  require('vibrainium').files()
end, { desc = 'Open the vibrainium unified search picker (Files mode)' })

vim.api.nvim_create_user_command('VibrainiumText', function()
  require('vibrainium').grep()
end, { desc = 'Open the vibrainium unified search picker (Text mode)' })

vim.api.nvim_create_user_command('VibrainiumSymbols', function()
  require('vibrainium').symbols()
end, { desc = 'Open the vibrainium unified search picker (Symbols mode)' })

vim.api.nvim_create_user_command('VibrainiumBufferNext', function()
  require('vibrainium').buffer_next()
end, { desc = 'Switch to next tab in the current editor split' })

vim.api.nvim_create_user_command('VibrainiumBufferPrev', function()
  require('vibrainium').buffer_prev()
end, { desc = 'Switch to previous tab in the current editor split' })

vim.api.nvim_create_user_command('VibrainiumBufferClose', function()
  require('vibrainium').buffer_close()
end, { desc = 'Close the active tab in the current editor split' })

vim.api.nvim_create_user_command('VibrainiumBufferMenu', function()
  require('vibrainium').buffer_menu()
end, { desc = 'Open context menu for the active tab in the current editor split' })

_G.VibrainiumWinbarSelect = function(minwid, _clicks, button, _modifiers)
  local pos = vim.fn.getmousepos()
  local winid = (pos and pos.winid and pos.winid > 0) and pos.winid or vim.api.nvim_get_current_win()
  local srow = (pos and pos.screenrow and pos.screenrow > 0) and pos.screenrow or 0
  local scol = (pos and pos.screencol and pos.screencol > 0) and pos.screencol or 0
  require('vibrainium').action('editor_tab.click', winid, minwid, button or 'l', srow, scol)
end

_G.VibrainiumWinbarClose = function(minwid, _clicks, _button, _modifiers)
  local pos = vim.fn.getmousepos()
  local winid = (pos and pos.winid and pos.winid > 0) and pos.winid or vim.api.nvim_get_current_win()
  require('vibrainium').action('editor_tab.close', winid, minwid)
end

${NvimMouseRouter.buildGlobalRightMouseLua()}
local function hide_global_tabline()
  pcall(vim.api.nvim_del_augroup_by_name, 'BufferLine')
  pcall(vim.api.nvim_del_augroup_by_name, 'BufferLineCmd')
  pcall(vim.api.nvim_del_augroup_by_name, 'BufferlineCmds')
  _G.nvim_bufferline = function()
    vim.o.tabline = ''
    vim.o.showtabline = 0
    return ''
  end
  vim.o.tabline = ''
  vim.o.showtabline = 0
end

hide_global_tabline()

local function bind_search_keymaps()
  hide_global_tabline()
  vim.schedule(hide_global_tabline)
  vim.keymap.set('n', '<leader>e', function()
    require('vibrainium').left_panel_toggle()
  end, { desc = 'Vibrainium: Toggle Left Pane' })
  vim.keymap.set('n', '<leader>j', function()
    require('vibrainium').bottom_panel_toggle()
  end, { desc = 'Vibrainium: Toggle Bottom Pane' })
  vim.keymap.set('n', '<leader>1', function()
    require('vibrainium').workspace_toggle()
  end, { desc = 'Vibrainium: Toggle Explorer [1]' })
  vim.keymap.set('n', '<leader>2', function()
    require('vibrainium').toggle()
  end, { desc = 'Vibrainium: Toggle VCS [2]' })
  vim.keymap.set('n', '<leader>3', function()
    require('vibrainium').problems_toggle()
  end, { desc = 'Vibrainium: Toggle Problems [3]' })
  vim.keymap.set('n', '<leader>4', function()
    require('vibrainium').agents_toggle()
  end, { desc = 'Vibrainium: Toggle AI Agents [4]' })
  vim.keymap.set('n', '<leader>ff', function()
    require('vibrainium').files()
  end, { desc = 'Vibrainium: Find Files' })
  vim.keymap.set('n', '<leader>sg', function()
    require('vibrainium').grep()
  end, { desc = 'Vibrainium: Search Text (ripgrep)' })
  vim.keymap.set('n', '<leader>ss', function()
    require('vibrainium').symbols()
  end, { desc = 'Vibrainium: Search Symbols (LSP)' })
  vim.keymap.set('n', '<leader>xx', function()
    require('vibrainium').problems_toggle()
  end, { desc = 'Vibrainium: Toggle Problems Panel' })
  vim.keymap.set('n', '<leader>aa', function()
    require('vibrainium').agents_toggle()
  end, { desc = 'Vibrainium: Toggle AI Agents Panel' })
  vim.keymap.set('x', '<leader>as', function()
    local s = vim.fn.line('v')
    local e = vim.fn.line('.')
    if s > e then s, e = e, s end
    local name = vim.api.nvim_buf_get_name(0) or ''
    local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
    vim.api.nvim_feedkeys(esc, 'nx', false)
    require('vibrainium').agent_send_selection(name, s, e)
  end, { desc = 'Vibrainium: Send @file#Lstart-Lend to Active Agent Chat' })
  vim.keymap.set('x', '<leader>aS', function()
    local s = vim.fn.line('v')
    local e = vim.fn.line('.')
    if s > e then s, e = e, s end
    local name = vim.api.nvim_buf_get_name(0) or ''
    local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
    vim.api.nvim_feedkeys(esc, 'nx', false)
    require('vibrainium').agent_send_selection_to(name, s, e)
  end, { desc = 'Vibrainium: Send @file#Lstart-Lend to Chosen Agent Chat' })
  vim.keymap.set('n', '<S-h>', function()
    require('vibrainium').buffer_prev()
  end, { desc = 'Vibrainium: Prev Split Tab' })
  vim.keymap.set('n', '<S-l>', function()
    require('vibrainium').buffer_next()
  end, { desc = 'Vibrainium: Next Split Tab' })
  vim.keymap.set('n', '[b', function()
    require('vibrainium').buffer_prev()
  end, { desc = 'Vibrainium: Prev Split Tab' })
  vim.keymap.set('n', ']b', function()
    require('vibrainium').buffer_next()
  end, { desc = 'Vibrainium: Next Split Tab' })
  vim.keymap.set('n', '<leader>bd', function()
    require('vibrainium').buffer_close()
  end, { desc = 'Vibrainium: Close Split Tab' })
  vim.keymap.set('n', '<leader>bo', function()
    require('vibrainium').buffer_close_others()
  end, { desc = 'Vibrainium: Close Other Split Tabs' })
  vim.keymap.set('n', '<leader>br', function()
    require('vibrainium').buffer_close_right()
  end, { desc = 'Vibrainium: Close Split Tabs to the Right' })
  vim.keymap.set('n', '<leader>ba', function()
    require('vibrainium').buffer_close_all()
  end, { desc = 'Vibrainium: Close All Split Tabs' })
  vim.keymap.set('n', '<leader>bm', function()
    require('vibrainium').buffer_menu()
  end, { desc = 'Vibrainium: Split Tab Context Menu' })
  vim.keymap.set('n', '<leader>by', function()
    require('vibrainium').buffer_copy_path()
  end, { desc = 'Vibrainium: Copy Active File Path' })
  vim.keymap.set('n', '<leader>bf', function()
    require('vibrainium').buffer_reveal()
  end, { desc = 'Vibrainium: Reveal Active File in Finder' })
  vim.keymap.set('n', '<leader>af', function()
    require('vibrainium').agent_send_file()
  end, { desc = 'Vibrainium: Add Active File to Agent Chat' })
end

bind_search_keymaps()
vim.api.nvim_create_autocmd('User', {
  pattern = 'VeryLazy',
  callback = bind_search_keymaps,
})

pcall(vim.api.nvim_del_augroup_by_name, 'Neotree_start_directory')
pcall(vim.api.nvim_del_augroup_by_name, 'neotree_auto_open')

local sync_group = vim.api.nvim_create_augroup('VibrainiumWorkspaceAutoSync', { clear = true })
local sync_pending = false
local last_editor_win = nil
local last_editor_name = ''
local last_key_was_mouse = false
pcall(vim.on_key, function(k)
  if k and #k > 0 then
    local ok_t, name = pcall(vim.fn.keytrans, k)
    if ok_t and name and name ~= '' then
      last_key_was_mouse = name:find('Mouse', 1, true) ~= nil
    end
  end
end, vim.api.nvim_create_namespace('vibrainium_mouse_tracker'))
local function capture_current_editor()
  local ok, win = pcall(vim.api.nvim_get_current_win)
  if not ok or not win or win <= 0 then
    return false
  end
  local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, win)
  if ok_cfg and cfg and cfg.relative and cfg.relative ~= '' then
    return false
  end
  local ok_buf, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok_buf or not buf or buf <= 0 then
    return false
  end
  if vim.bo[buf].buftype ~= '' then
    return false
  end
  last_editor_win = win
  last_editor_name = vim.api.nvim_buf_get_name(buf) or ''
  return true
end
vim.api.nvim_create_autocmd({ 'BufAdd', 'BufEnter', 'WinEnter', 'BufWinEnter', 'BufModifiedSet', 'BufDelete', 'BufWipeout', 'WinClosed', 'WinResized' }, {
  group = sync_group,
  callback = function()
    hide_global_tabline()
    capture_current_editor()
    if sync_pending then
      return
    end
    sync_pending = true
    vim.schedule(function()
      sync_pending = false
      hide_global_tabline()
      local ok, win = pcall(vim.api.nvim_get_current_win)
      if not ok or not win or win <= 0 then
        return
      end
      local ok_buf, buf = pcall(vim.api.nvim_win_get_buf, win)
      if ok_buf and buf and buf > 0 then
        local ft = vim.bo[buf].filetype or ''
        if ft == 'vibrainium-tabbar' or ft == 'vibrainium-bottom-tabbar' then
          local trigger = last_key_was_mouse and 'mouse' or 'key'
          pcall(function()
            require('vibrainium').action('panel_tabbar.win_enter', trigger)
          end)
          return
        end
      end
      pcall(function()
        require('vibrainium').action('editor_tab.sync')
      end)
      capture_current_editor()
      local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, win)
      if ok_cfg and cfg and cfg.relative and cfg.relative ~= '' then
        return
      end
      if not ok_buf or not buf or buf <= 0 then
        return
      end
      if vim.bo[buf].buftype ~= '' then
        return
      end
      local name = vim.api.nvim_buf_get_name(buf) or ''
      if name ~= '' then
        pcall(function()
          require('vibrainium').action('workspace.sync_active_file', name, win)
        end)
      end
    end)
  end,
})

vim.api.nvim_create_autocmd('VimEnter', {
  callback = function()
    hide_global_tabline()
    pcall(vim.api.nvim_del_augroup_by_name, 'Neotree_start_directory')
    pcall(vim.api.nvim_del_augroup_by_name, 'neotree_auto_open')
    require('vibrainium').workspace_open()
  end,
})
''';
  }

  static String _generateInitLua({
    required String socketPath,
    String? devPackagePath,
  }) {
    final escapedSocket = socketPath.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final String cmdExpr;
    if (devPackagePath == null) {
      cmdExpr = "{ 'vibrainium', 'daemon', '--socket', '$escapedSocket' }";
    } else {
      final escapedPkg = devPackagePath.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
      cmdExpr =
          "{ 'dart', 'run', '--verbosity=error', '$escapedPkg/bin/vibrainium.dart', 'daemon', '--socket', '$escapedSocket', '--dev', '$escapedPkg' }";
    }

    return '''
local M = {}

local chan_id = nil
local connecting = false
local pending_actions = {}
local socket_path = '$escapedSocket'
local sock_mode = (socket_path:match('^127%.0%.0%.1:%d+\$') or socket_path:match('^localhost:%d+\$')) and 'tcp' or 'pipe'

local function try_connect()
  local ok, id = pcall(vim.fn.sockconnect, sock_mode, socket_path, { rpc = true })
  if ok and id and id > 0 then
    chan_id = id
    return id
  end
  return nil
end

local function flush_pending()
  if not chan_id or chan_id <= 0 then
    return
  end
  local queue = pending_actions
  pending_actions = {}
  for _, item in ipairs(queue) do
    pcall(vim.rpcnotify, chan_id, 'vibrainium_action', unpack(item))
  end
end

local function spawn_and_connect()
  if connecting then
    return
  end
  connecting = true

  local cmd = $cmdExpr
  vim.fn.jobstart(cmd, { detach = true })

  local attempts = 0
  local function poll()
    attempts = attempts + 1
    if try_connect() then
      connecting = false
      flush_pending()
      return
    end
    if attempts < 60 then
      vim.defer_fn(poll, 50)
    else
      connecting = false
      vim.notify('[Vibrainium] Timed out waiting for daemon socket: ' .. socket_path, vim.log.levels.ERROR)
    end
  end

  vim.defer_fn(poll, 50)
end

function M.action(name, ...)
  if chan_id and chan_id > 0 then
    local ok = pcall(vim.rpcnotify, chan_id, 'vibrainium_action', name, ...)
    if ok then
      return
    end
    chan_id = nil
  end

  if try_connect() then
    vim.rpcnotify(chan_id, 'vibrainium_action', name, ...)
    return
  end

  table.insert(pending_actions, { name, ... })
  spawn_and_connect()
end

function M.files()
  M.action('search.files')
end

function M.grep()
  M.action('search.text')
end

function M.symbols()
  M.action('search.symbols')
end

function M.search(mode)
  local m = (mode or 'files'):lower()
  if m == 'text' or m == 'grep' then
    M.grep()
  elseif m == 'symbols' or m == 'symbol' then
    M.symbols()
  else
    M.files()
  end
end

function M.search_close()
  M.action('search.close')
end

function M.open()
  M.action('open')
end

function M.close()
  M.action('close')
end

function M.toggle()
  M.action('toggle')
end

function M.refresh()
  M.action('refresh')
end

function M.repo_picker()
  M.action('repo_picker')
end

function M.workspace_open()
  M.action('workspace.open')
end

function M.workspace_close()
  M.action('workspace.close')
end

function M.workspace_toggle()
  M.action('workspace.toggle')
end

function M.left_panel_toggle()
  M.action('left_panel.toggle')
end

function M.bottom_panel_toggle()
  M.action('bottom_panel.toggle')
end

function M.workspace_refresh()
  M.action('workspace.refresh')
end

function M.workspace_reveal()
  M.action('workspace.reveal')
end

function M.problems_open()
  M.action('problems.open')
end

function M.problems_close()
  M.action('problems.close')
end

function M.problems_toggle()
  M.action('problems.toggle')
end

function M.problems_refresh()
  M.action('problems.refresh')
end

function M.agents_open()
  M.action('agents.open')
end

function M.agents_close()
  M.action('agents.close')
end

function M.agents_toggle()
  M.action('agents.toggle')
end

function M.agents_refresh()
  M.action('agents.refresh')
end

function M.agent_new_antigravity()
  M.action('agent.new_antigravity')
end

function M.agent_new_claude()
  M.action('agent.new_claude')
end

function M.agent_send_selection(file_path, start_line, end_line)
  local path = file_path or vim.api.nvim_buf_get_name(0) or ''
  local s = start_line or vim.fn.line("'<")
  local e = end_line or vim.fn.line("'>")
  M.action('agent.send_selection', path, s, e)
end

function M.agent_send_selection_to(file_path, start_line, end_line)
  local path = file_path or vim.api.nvim_buf_get_name(0) or ''
  local s = start_line or vim.fn.line("'<")
  local e = end_line or vim.fn.line("'>")
  M.action('agent.send_selection_to', path, s, e)
end

function M.agent_send_file(file_path)
  local path = file_path or vim.api.nvim_buf_get_name(0) or ''
  M.action('agent.send_file', path)
end

function M.diff_toggle_mode()
  M.action('diff.toggle_mode')
end

function M.diff_copy_review()
  M.action('diff.copy_review')
end

function M.diff_compare(left, right)
  M.action('diff.compare', left, right)
end

function M.diff_close()
  M.action('diff.close')
end

function M.buffer_next()
  M.action('buffer.next')
end

function M.buffer_prev()
  M.action('buffer.prev')
end

function M.buffer_close()
  M.action('buffer.close')
end

function M.buffer_close_others()
  M.action('buffer.close_others')
end

function M.buffer_close_right()
  M.action('buffer.close_right')
end

function M.buffer_close_all()
  M.action('buffer.close_all')
end

function M.buffer_copy_path()
  M.action('buffer.copy_path')
end

function M.buffer_reveal()
  M.action('buffer.reveal')
end

function M.buffer_menu()
  M.action('buffer.menu')
end

function M.tab_next()
  M.action('tab.next')
end

function M.tab_prev()
  M.action('tab.prev')
end

function M.reload()
  M.action('reload')
end

function M.setup(_opts)
end

return M
''';
  }
}
