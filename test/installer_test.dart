import 'dart:io';
import 'package:test/test.dart';
import 'package:vibrainium/vibrainium.dart';

void main() {
  group('VibrainiumInstaller', () {
    late Directory tempSiteDir;
    late Directory fakeRepoDir;

    setUp(() async {
      tempSiteDir = await Directory.systemTemp.createTemp('vibrainium_site_test_');
      fakeRepoDir = await Directory.systemTemp.createTemp('vibrainium_repo_test_');
      final binDir = Directory('${fakeRepoDir.path}/vibrainium/bin');
      await binDir.create(recursive: true);
      await File('${binDir.path}/vibrainium.dart').writeAsString('// entrypoint');
    });

    tearDown(() async {
      if (await tempSiteDir.exists()) {
        await tempSiteDir.delete(recursive: true);
      }
      if (await fakeRepoDir.exists()) {
        await fakeRepoDir.delete(recursive: true);
      }
    });

    test('install() writes real files (no symlinks) into site directory using system vibrainium binary', () async {
      final legacyPackDir = Directory('${tempSiteDir.path}/pack/vibrainium/start/vibrainium');
      await legacyPackDir.create(recursive: true);

      final installedPath = await VibrainiumInstaller.install(
        siteDir: tempSiteDir.path,
      );

      final entityType = await FileSystemEntity.type(installedPath, followLinks: false);
      expect(entityType, FileSystemEntityType.directory);
      expect(await Directory('${tempSiteDir.path}/pack/vibrainium').exists(), isFalse);

      final pluginLua = File('$installedPath/plugin/vibrainium.lua');
      final initLua = File('$installedPath/lua/vibrainium/init.lua');
      expect(await pluginLua.exists(), isTrue);
      expect(await initLua.exists(), isTrue);

      final initContent = await initLua.readAsString();
      expect(initContent, contains("local cmd = { 'vibrainium', 'daemon', '--socket'"));
      expect(initContent, contains("vim.fn.jobstart(cmd, { detach = true })"));
      expect(initContent, contains(r"local sock_mode = (socket_path:match('^127%.0%.0%.1:%d+$') or socket_path:match('^localhost:%d+$')) and 'tcp' or 'pipe'"));
      expect(initContent, contains("pcall(vim.fn.sockconnect, sock_mode, socket_path, { rpc = true })"));

      final pluginContent = await pluginLua.readAsString();
      expect(pluginContent, contains("nvim_create_user_command('Vibrainium'"));
      expect(pluginContent, contains("'Vcs.Open'"));
      expect(pluginContent, contains("'Workspace.Open'"));
      expect(pluginContent, contains("nvim_create_user_command('VibrainiumVcsOpen'"));
      expect(pluginContent, contains("nvim_create_user_command('VibrainiumWorkspaceOpen'"));
      expect(pluginContent, contains("nvim_create_autocmd('VimEnter'"));
      expect(pluginContent, contains("nvim_del_augroup_by_name, 'Neotree_start_directory'"));
      expect(pluginContent, contains("require('vibrainium').workspace_open()"));
      expect(pluginContent, contains("'Search.Files'"));
      expect(pluginContent, contains("'Search.Text'"));
      expect(pluginContent, contains("'Search.Symbols'"));
      expect(pluginContent, contains("'Problems.Open'"));
      expect(pluginContent, contains("'Problems.Toggle'"));
      expect(pluginContent, contains("nvim_create_user_command('VibrainiumProblemsToggle'"));
      expect(pluginContent, contains("<leader>ff"));
      expect(pluginContent, contains("<leader>sg"));
      expect(pluginContent, contains("<leader>ss"));
      expect(pluginContent, contains("<leader>xx"));
      expect(pluginContent, contains("vim.o.showtabline = 0"));
      expect(pluginContent, contains("vim.o.tabline = ''"));
      expect(pluginContent, contains("nvim_del_augroup_by_name, 'BufferLine'"));
      expect(pluginContent, contains("nvim_del_augroup_by_name, 'BufferlineCmds'"));
      expect(pluginContent, contains("_G.nvim_bufferline = function()"));
      expect(pluginContent, contains("_G.VibrainiumWinbarSelect"));
      expect(pluginContent, contains("_G.VibrainiumWinbarClose"));
      expect(pluginContent, contains("'Buffer.Next'"));
      expect(pluginContent, contains("'Buffer.Prev'"));
      expect(pluginContent, contains("'Buffer.Close'"));
      expect(pluginContent, contains("'Buffer.CloseOthers'"));
      expect(pluginContent, contains("'Buffer.CloseRight'"));
      expect(pluginContent, contains("'Buffer.CloseAll'"));
      expect(pluginContent, contains("'Buffer.CopyPath'"));
      expect(pluginContent, contains("'Buffer.Reveal'"));
      expect(pluginContent, contains("'Buffer.Menu'"));
      expect(pluginContent, contains("<leader>bm"));
      expect(pluginContent, contains("<leader>bo"));
      expect(pluginContent, contains("<leader>br"));
      expect(pluginContent, contains("<leader>ba"));
      expect(pluginContent, contains("<leader>by"));
      expect(pluginContent, contains("<leader>bf"));
      expect(pluginContent, contains("<leader>af"));
      expect(pluginContent, contains("editor_tab.right_click"));
      expect(pluginContent, contains("vibrainium_right_mouse_action"));
      expect(pluginContent, contains("'<2-RightMouse>'"));
      expect(pluginContent, contains("'<3-RightMouse>'"));
      expect(pluginContent, contains("'<4-RightMouse>'"));
      expect(pluginContent, contains("vim.keymap.set({ 'n', 'v', 'i', 't' }, key"));
      expect(pluginContent, contains("panel_tabbar.win_enter"));
      expect(pluginContent, contains("editor_tab.sync"));
      expect(pluginContent, contains("'Agents.Open'"));
      expect(pluginContent, contains("'Agents.Toggle'"));
      expect(pluginContent, contains("'Agents.SendSelection'"));
      expect(pluginContent, contains("nvim_create_user_command('VibrainiumAgentsToggle'"));
      expect(pluginContent, contains("nvim_create_user_command('VibrainiumAgentSendSelection'"));
      expect(pluginContent, contains("<leader>aa"));
      expect(pluginContent, contains("<leader>as"));
      expect(pluginContent, contains("<leader>aS"));
      expect(pluginContent, contains("<leader>e"));
      expect(pluginContent, contains("<leader>j"));
      expect(pluginContent, contains("<leader>1"));
      expect(pluginContent, contains("<leader>2"));
      expect(pluginContent, contains("<leader>3"));
      expect(pluginContent, contains("<leader>4"));
      expect(pluginContent, contains("nvim_create_user_command('VibrainiumLeftPanelToggle'"));
      expect(pluginContent, contains("nvim_create_user_command('VibrainiumBottomPanelToggle'"));
      expect(pluginContent, contains("'Panel.ToggleLeft'"));
      expect(pluginContent, contains("'Panel.ToggleBottom'"));
      expect(initContent, contains("function M.left_panel_toggle()"));
      expect(initContent, contains("function M.bottom_panel_toggle()"));
    });

    test('install(devPath: ...) writes init.lua using dart run from dev path', () async {
      final installedPath = await VibrainiumInstaller.install(
        devPath: fakeRepoDir.path,
        siteDir: tempSiteDir.path,
      );

      final initLua = File('$installedPath/lua/vibrainium/init.lua');
      final initContent = await initLua.readAsString();
      expect(
        initContent,
        contains(
          "'${fakeRepoDir.path}/vibrainium/bin/vibrainium.dart', 'daemon', '--socket'",
        ),
      );
      expect(
        initContent,
        contains("'--dev', '${fakeRepoDir.path}/vibrainium'"),
      );
    });

    test('uninstall() removes installed plugin files from site directory', () async {
      await VibrainiumInstaller.install(siteDir: tempSiteDir.path);
      final removed = await VibrainiumInstaller.uninstall(siteDir: tempSiteDir.path);
      expect(removed, isTrue);
      expect(await File('${tempSiteDir.path}/plugin/vibrainium.lua').exists(), isFalse);
      expect(await Directory('${tempSiteDir.path}/lua/vibrainium').exists(), isFalse);

      final removedAgain = await VibrainiumInstaller.uninstall(siteDir: tempSiteDir.path);
      expect(removedAgain, isFalse);
    });
  });
}
