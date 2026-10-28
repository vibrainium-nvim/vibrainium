import 'dart:io';

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
  ['tab.next'] = function() require('vibrainium').tab_next() end,
  ['tab.prev'] = function() require('vibrainium').tab_prev() end,
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
  'Tab.Next',
  'Tab.Prev',
  'Reload',
}

vim.api.nvim_create_user_command('Vibrainium', function(opts)
  local key = table.concat(opts.fargs, '.'):lower()
  local fn = subcommands[key]
  if fn then
    fn()
  else
    vim.notify('[vibrainium] Unknown subcommand: ' .. table.concat(opts.fargs, ' '), vim.log.levels.ERROR)
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

vim.api.nvim_create_user_command('VibrainiumReload', function()
  require('vibrainium').reload()
end, { desc = 'Hot reload the vibrainium Dart VM isolate' })
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

local function try_connect()
  local ok, id = pcall(vim.fn.sockconnect, 'pipe', socket_path, { rpc = true })
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
  for _, act in ipairs(queue) do
    pcall(vim.rpcnotify, chan_id, 'vibrainium_action', act)
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
      vim.notify('[vibrainium] Timed out waiting for daemon socket: ' .. socket_path, vim.log.levels.ERROR)
    end
  end

  vim.defer_fn(poll, 50)
end

function M.action(name)
  if chan_id and chan_id > 0 then
    local ok = pcall(vim.rpcnotify, chan_id, 'vibrainium_action', name)
    if ok then
      return
    end
    chan_id = nil
  end

  if try_connect() then
    vim.rpcnotify(chan_id, 'vibrainium_action', name)
    return
  end

  table.insert(pending_actions, name)
  spawn_and_connect()
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

function M.workspace_refresh()
  M.action('workspace.refresh')
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
