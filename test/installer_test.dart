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
      expect(initContent, contains("vim.fn.sockconnect"));

      final pluginContent = await pluginLua.readAsString();
      expect(pluginContent, contains("nvim_create_user_command('Vibrainium'"));
      expect(pluginContent, contains("'Vcs.Open'"));
      expect(pluginContent, contains("'Workspace.Open'"));
      expect(pluginContent, contains("nvim_create_user_command('VibrainiumVcsOpen'"));
      expect(pluginContent, contains("nvim_create_user_command('VibrainiumWorkspaceOpen'"));
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
